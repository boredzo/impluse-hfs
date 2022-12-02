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

enum {
	///Size of the blocks used for the boot blocks, volume header, and VBM. Allocation blocks (used for the catalog file, extents file, and user data) use a different size, indicated by drAlBlkSiz in the volume header.
	kISOStandardBlockSize = 512
};

#endif /* ImpSizeUtilities_h */
