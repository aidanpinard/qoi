# QOI Encoder and Decoder

A simple attempt at implementing the qoi encoder and decoder in V. This is an almost direct conversion of the [reference C encoder and decoder](https://github.com/phoboslab/qoi)

# TODO
- Improve readability of code with appropriate comments
- Write tests
- Rewrite error messages
- Separate repeated code into functions (if necessary)
- Create benchmarker
- Implement streaming encoders and decoders
- Test different pixel data types (currently using `[4]byte`)
- Add grayscale image support
- Test direct array access to boost speed when reading from arrays (need to ensure bounds checking)