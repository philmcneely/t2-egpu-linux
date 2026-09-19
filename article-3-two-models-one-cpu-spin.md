# Two Models, One Box, and the Bug That Ran My Second GPU on the CPU

*(Episode 3 of the Mac-Mini-eGPU saga. [Episode 1](article.md) was getting a single AMD GPU to do inference over Thunderbolt on a T2 Mac Mini at all; the earlier chapters cover that win and the expensive Thunderbolt-2 dead-end that came before it. This one is the sequel problem: making **two** cards in **one** box each serve a model, full-time, without the whole thing falling over. It took a genuinely embarrassing amount of flailing to get right, and the root cause was not even slightly what I assumed.)*

## The setup

The box in question ("apol") is a 2018 Mac Mini running T2 Linux with **two AMD Radeon VII cards** in Thunderbolt-3 eGPU enclosures. The plan was simple and, on paper, already solved: run one `llama-server` process pinned to each card (`ROCR_VISIBLE_DEVICES=0` and `=1`), each serving the same 27B model, and let it churn on slow unattended work. Two cards, two models, one quiet little box in a closet.

And it *did* work — intermittently. Which is the worst way for anything to work, because "intermittently" means you don't find out it's broken until it matters.

## The night it fell over

It started, as these things do, with a power event. The box got cold power-cycled. On these Thunderbolt-eGPU setups a cold cycle is a dice roll — sometimes both cards come back on the bus promptly, sometimes the second one enumerates a couple of minutes late, and I have learned the hard way to *wait* before concluding a card is dead. This time both eventually came up, but under sustained load one card dropped off the Thunderbolt bus entirely.

Here is where I made the actual problem worse. When a card vanishes mid-inference, the process serving it doesn't die cleanly — it starts **spinning on the CPU**, pegging every core it can grab. Load climbed to 15 on a 12-thread box, the scheduler couldn't service SSH anymore, and the machine went from "up and pingable" to "up and completely unreachable." I couldn't get a shell to kill the runaway. And because it's a Mac Mini with no auto-power-on, I couldn't safely remote-cycle it either. Someone had to walk over and hold the power button.

I'd love to say I calmly diagnosed it from there. Instead I rebooted it about nine times over two days chasing the wrong thing, and a couple of those reboots glitched the GPU's SMU controller and made *new* problems. The lesson that should have come first came last: **stop rebooting a box you don't understand yet.**

## The real mystery

Once the hardware settled, the actual bug showed its face, and it was maddeningly consistent: **one model would serve fine, and the second would load its weights into VRAM and then spin at ~200% CPU forever, never becoming ready.** Whichever process came up first won. The second always hung.

I burned a lot of hours on theories that were *reasonable* and *wrong*:

- **"It's RAM."** Two ~14 GB models on a box with 16 GB of system RAM — surely it's overrunning. I checked: 12 GB free, zero OOM kills. Not it. *But* — and this matters — chasing it turned up two genuine bugs: the containers were running with a **`memlock` limit of 8 KB** (ROCm needs to pin *gigabytes*, so its SVM mapping was failing with `exceeds resident system memory limit`), and loading the second model really does pressure the RAM during the copy. Both real, both fixed (`--ulimit memlock=-1`, a smaller compute batch, a page-cache drop). Neither fixed the spin.
- **"It's a slow JIT compile."** These GDN-architecture models JIT-compile GPU kernels on first load, which is CPU-heavy and slow. Plausible! Except the compiled-kernel cache wasn't growing and no compiler process was running. Not it.
- **"Reboot it."** No. See above.
- **"Isolate each card in its own container."** Reasonable instinct — and wrong, because both processes talk to the same `/dev/kfd` kernel device. Docker can't split that.

## The breakthrough: measure, don't theorize

The thing that finally cracked it was the cheapest possible move I should have made on hour one: I `strace`d the spinning process.

It was making **almost zero syscalls.** ~200% CPU, and essentially no kernel calls. That single fact killed every remaining theory. A process waiting on the GPU shows a storm of ioctls; this one was silent. It wasn't waiting on anything — it was **spinning in userspace, doing computation on the CPU.** The "second model" wasn't slow or stuck loading. It had quietly fallen back to running the model's math on the CPU, which for this architecture is so slow it looks like an infinite hang.

That reframed the whole problem, and it pointed straight at the thing I'd been told from the start to never allow: **inference must never touch the CPU.** This was exactly that, happening silently.

## The cause (it's a known bug)

With the right search terms, the answer was already written down. It's an upstream ROCm/HIP issue:

- [llama.cpp #29098](https://github.com/ggml-org/llama.cpp/issues/29098) — **two `llama-server` processes on the same ROCm stack, with HIP graphs enabled, deadlock the second one** and pin the GPU/CPU. The reporter's fix: rebuild with HIP graphs off.
- [llama.cpp #12991](https://github.com/ggml-org/llama.cpp/issues/12991) — the same "multiple instances lock up" symptom.
- [ROCm #6522](https://github.com/ROCm/ROCm/issues/6522) — the HSA runtime's event loop can livelock at 100% of a core after a queue eviction. That's the residual spin under it.

HIP graphs are a performance feature (capturing a kernel sequence and replaying it cheaply). But when two processes share one GPU driver and both use graphs, the second one's graph machinery deadlocks against the first. And critically, the *runtime* environment variable that's supposed to disable graphs (`GGML_CUDA_DISABLE_GRAPHS=1`) only *halved* the spin for me — because the prebuilt image had graphs compiled in. You have to turn them off at **build** time.

## The fix

I rebuilt `llama.cpp` **from the same working image** (so I kept the hard-won GPU-specific BLAS backend — don't throw that away) with one flag flipped:

```sh
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
  cmake -S . -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx906 \
        -DGGML_HIP_GRAPHS=OFF -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
cmake --build build -j"$(nproc)" --target llama-server
```

With graphs off, the second runner still spins on the CPU during its graph-build warmup — for **two to eight minutes**, longer while the first model is actively serving — but then it *finishes*, drops to 0% CPU, and starts answering on the GPU. That "it finishes now" is the entire difference. Both models. Both cards. Full time.

(A couple of things that did **not** help, so you don't repeat them: `HSA_TOOLS_DISABLE_REGISTER=1` is a fix for a different GPU generation and did nothing here; `GPU_MAX_HW_QUEUES=1` didn't help; and `HSA_XNACK=1` is a non-starter because this card's target is built `xnack-`.)

## The part that actually mattered more than the fix

Fixing the bug was satisfying. But the bug will recur — hardware drops cards, drivers regress. What changed the box from *fragile* to *dependable* was the guardrails I bolted on after being burned:

1. **A "GPU-only" watchdog.** A tiny service watches every runner and kills any that spins on the CPU. It's *warmup-aware* — patient with a process that's never been healthy yet (that legitimate 2–8 minute warmup), but fast to kill a process that *was* serving and started spilling. And it resets that judgment per container instance, because "this container was healthy an hour ago" is not the same container after a restart. (I learned that one by having the watchdog murder a perfectly good warmup because it remembered the *previous* instance.)
2. **A hard CPU cap on each runner.** Two cores, max. This is the single most valuable line: even if something spins, it *physically cannot* starve the box or lock you out of SSH again. The failure that took the machine fully offline is now, at worst, a logged blip.

The box went from "one hardware hiccup = a two-hour outage and a walk to the closet" to "a hiccup is a line in a log."

## Lessons, honestly

- **`strace` on hour one, not hour twenty.** The zero-syscalls reading collapsed a dozen theories instantly. I theorized when I should have measured.
- **Don't reboot a box you don't understand.** Nine reboots created problems that didn't exist before. Reversible-looking actions aren't free.
- **Config env vars ≠ build flags.** The runtime "disable graphs" knob was a red herring; the real fix was in the build.
- **Contain what you can't prevent.** You can't stop a driver from mishandling a hot-unplugged GPU. You *can* cap the process so its bad behavior is harmless. Prevention plus containment.
- **The RAM theory being "wrong" still found two real bugs.** Wrong hypotheses that you actually test are not wasted; they clear the board and sometimes hand you fixes on the way past.

The little low-power box is still in the closet, still drawing its modest watts, now serving two models on two GPUs without drama. Which was the entire point — a dedicated, unattended workhorse that doesn't tie up the machines I actually need. It just took an episode's worth of learning that "it works intermittently" is a bug report, not a status.

*I used Claude to help drive the debugging, the research, and this write-up. The strace-it-first lesson is one it should have suggested sooner too — we both got there eventually.*
