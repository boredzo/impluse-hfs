//
//  ImpSizeUtilities.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#ifndef ImpSizeUtilities_h
#define ImpSizeUtilities_h

///Returns the next number that is less than or equal to size, and is a multiple of factor.
#define macro_ImpNextMultipleOfSize(size, factor) \
	( \
		(size) % (factor) == 0 \
		? (size) \
		: ((size) + ((factor) - (size) % (factor))) \
	)
static inline size_t ImpNextMultipleOfSize(size_t const size, size_t const factor) {
	if (size % factor == 0) {
		return size;
	} else {
		size_t const roundedUpSize = size + (factor - size % factor);
		return roundedUpSize;
	}
}

#endif /* ImpSizeUtilities_h */
