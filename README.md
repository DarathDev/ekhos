# Ekhos (ɛkoʊ)

Ekhos (pronounced like "Echos") is a simulator for [Field II](https://field-ii.dk), with CPU and Vulkan GPU backends.

While it can perform simulations for arbitrary sets of rectangular and triangular elements, the current front end only has functions for easy simulations of row column arrays.

## Requirements

- [Odin](https://github.com/odin-lang/Odin)
- [Slang](https://github.com/shader-slang/slang)

### Optional

- [MATLAB](https://www.mathworks.com/products/matlab.html)

## Building the Library

```shell
odin run . -- -lib -matlab
```

Note: MATLAB will crash if a debug trap is hit and no debugger is attached.

The build program accepts the following options:

| Option | Description |
| --- | --- |
| `-lib` or `-l` | Build the Ekhos static library (the default). |
| `-test`, `-tests`, or `-t` | Build the test executable. |
| `-debug` or `-d` | Build with debug information and runtime checks. |
| `-release` or `-r` | Build an optimized release. |
| `-matlab` | Also copy the library to `matlab/EkhosLib.a`. |
| `-profile` | Enable profiling instrumentation. |
| `-cpu-stage-timing` | Enable CPU stage timing instrumentation. |
| `-gpu-stage-timing` | Enable Vulkan GPU stage timing instrumentation. |
| `-plan-stage-timing` | Enable CPU and Vulkan GPU planning stage timing. |
| `-all-stage-timing` | Enable CPU, Vulkan GPU, and planning stage timing. |
| `-asan` | Enable AddressSanitizer in debug builds. |
| `-no-break` | Disable debugger breakpoints from the messenger. |

For example, to build an optimized library for MATLAB:

```shell
odin run . -- -release -lib -matlab
```

## Testing

```shell
odin run . -- -test
./bin/release/ekhosTests
```

To compare CPU and Vulkan GPU simulation times for the same scenarios, build and run the benchmark mode:

```shell
odin run . -- -test -release -benchmark
./bin/release/ekhosTests
```

Each benchmark warms up both backends, then reports average and minimum simulation time plus the GPU speedup. Set `BENCHMARK_ITERATIONS` in `test/test_simulations.odin` to change the sample count.

## Citations

The algorithm used in the simulator is based on this work:

```
J. A. Jensen and N. B. Svendsen, "Calculation of pressure fields from arbitrarily shaped, apodized, and excited ultrasound transducers," in IEEE Transactions on Ultrasonics, Ferroelectrics, and Frequency Control, vol. 39, no. 2, pp. 262-267, March 1992, doi: 10.1109/58.139123.
```

See the following for background knowledge on creating a linear model of ultrasound

```
J.A. Jensen: Linear description of ultrasound imaging systems, Notes for the International Summer School on Advanced Ultrasound Imaging, Technical University of Denmark July 5 to July 9, 1999, Technical University of Denmark, June, 1999.
```

And finally a special thanks to [Field II](https://field-ii.dk) for establishing a gold standard for ultrasound simulation.
