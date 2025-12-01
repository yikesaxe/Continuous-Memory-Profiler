# Continuous Memory Profiler

This repository contains research and evaluation tools for live heap profiling and memory sampling strategies.

## Projects

### stateless-sampling

A comprehensive evaluation harness for stateless memory sampling strategies using `LD_PRELOAD`-based interception. This project implements and compares four different sampling schemes:

- **STATELESS_HASH**: Address-based XOR-shift hash sampling
- **POISSON_HEADER**: Byte-based Poisson process sampling
- **PAGE_HASH**: Page-based hash sampling
- **HYBRID**: Combination of Poisson (small allocs) and hash (large allocs)

**Key Features**:
- Multi-run statistical analysis with percentile distributions
- Synthetic and real-world workload evaluation
- Performance overhead measurements
- Sampling bias detection (dead zone metrics)
- Comprehensive visualization and reporting

See [`stateless-sampling/README.md`](stateless-sampling/README.md) for detailed usage instructions and [`stateless-sampling/stateless-sampling-tests.md`](stateless-sampling/stateless-sampling-tests.md) for the complete evaluation report.

## License

See individual project directories for license information.

