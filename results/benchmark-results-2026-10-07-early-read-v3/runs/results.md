**Speed.** Decode tok/s, mean of the 4 runs of each setting, and the change from off.

|case|off|router|fitted|fitted ×2|
|---|---:|---:|---:|---:|
|short|3.652|4.341 (+18.9%)|4.527 (+24.0%)|5.011 (+37.2%)|
|medium|3.302|3.913 (+18.5%)|4.117 (+24.7%)|4.697 (+42.3%)|
|long|3.036|3.542 (+16.7%)|3.674 (+21.0%)|4.241 (+39.7%)|

**Each step, between adjacent runs.** Change in tok/s, later setting over earlier, per pair of adjacent runs.

- **router vs off:** faster in 12 of 12 pairs, median +18.3%.
- **fitted vs router:** faster in 12 of 12 pairs, median +4.4%.
- **fitted ×2 vs fitted:** faster in 12 of 12 pairs, median +13.4%.

|step|case|faster in|median|each pair, in run order|
|---|---|---|---:|---|
|router vs off|short|4 of 4|+18.7%|+18.1, +20.1, +19.0, +18.4|
|router vs off|medium|4 of 4|+18.9%|+16.4, +19.1, +18.6, +19.9|
|router vs off|long|4 of 4|+16.8%|+16.4, +17.2, +17.3, +15.8|
|fitted vs router|short|4 of 4|+4.3%|+3.7, +3.9, +4.9, +4.7|
|fitted vs router|medium|4 of 4|+4.7%|+7.4, +4.2, +5.1, +4.3|
|fitted vs router|long|4 of 4|+4.0%|+4.5, +1.5, +3.5, +5.4|
|fitted ×2 vs fitted|short|4 of 4|+11.5%|+11.8, +11.9, +11.3, +7.7|
|fitted ×2 vs fitted|medium|4 of 4|+13.7%|+16.9, +14.9, +12.0, +12.5|
|fitted ×2 vs fitted|long|4 of 4|+14.8%|+14.4, +15.2, +14.3, +17.8|

**Noise.** Adjacent runs of the same setting differ by a median of 1.0% (largest 4.2%, 9 pairs).

**Runs more than 3% from the median of their setting and case:** medium-review run 4 (fitted ×2): 4.863 tok/s, +4.6% from its setting's median; long-synthesis run 13 (fitted ×2): 4.357 tok/s, +3.5% from its setting's median.

**Expert reads per token** with the early read on:

|case|needed/tok|router: loaded early, precision|fitted: loaded early, precision|fitted ×2: loaded early, precision|
|---|---:|---:|---:|---:|
|short|77.45|19.87, 0.685|24.10, 0.831|41.51, 0.716|
|medium|83.93|20.41, 0.704|24.44, 0.843|42.73, 0.737|
|long|92.08|20.96, 0.723|25.23, 0.870|44.91, 0.774|

Order per case, 2 times: off, router, fitted, fitted ×2, fitted ×2, fitted, router, off. 48 of 48 runs finished. 120-second pause before each run; one discarded warmup per case (fitted ×2). MacBook Air.
