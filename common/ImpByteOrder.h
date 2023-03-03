//
//  ImpByteOrder.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-29.
//

///In which we make byte-swapping values into and out of file-system structures less of a pain in the ass.
#ifndef ImpByteOrder_h
#define ImpByteOrder_h

#define L8(x) (x)
static inline int8_t ImpSwapInt8BigToHost(int8_t x) {
	return x;
}

///Swap a value (typically being retrieved from a member of one of HFS's structures) from big-endian byte order to host byte order.
#define L(x) _Generic( (x), \
	char: ImpSwapInt8BigToHost((x)), \
	signed char: ImpSwapInt8BigToHost((x)), \
	unsigned char: ImpSwapInt8BigToHost((x)), \
	short: CFSwapInt16BigToHost(x), \
	unsigned short: CFSwapInt16BigToHost(x), \
	int: CFSwapInt32BigToHost(x), \
	unsigned int: CFSwapInt32BigToHost(x), \
	long: CFSwapInt64BigToHost(x), \
	unsigned long: CFSwapInt64BigToHost(x), \
	long long: CFSwapInt64BigToHost(x), \
	unsigned long long: CFSwapInt64BigToHost(x), \
	\
	default: CFSwapInt32BigToHost(x) \
)

///Swap a value from host byte order to big-endian byte order (typically before storing it into a member of one of HFS+'s structures).
#define S(dst, x) _Generic( (dst), \
	char: (dst) = (x), \
	signed char: (dst) = (x), \
	unsigned char: (dst) = (x), \
	short: (dst) = CFSwapInt16HostToBig(x), \
	unsigned short: (dst) = CFSwapInt16HostToBig(x), \
	int: (dst) = CFSwapInt32HostToBig(x), \
	unsigned int: (dst) = CFSwapInt32HostToBig(x), \
	long: (dst) = CFSwapInt64HostToBig(x), \
	unsigned long: (dst) = CFSwapInt64HostToBig(x), \
	long long: (dst) = CFSwapInt64HostToBig(x), \
	unsigned long long: (dst) = CFSwapInt64HostToBig(x), \
	\
	default: (dst) = CFSwapInt32HostToBig(x) \
)
#define S8(x) (x)
#define S16(x) CFSwapInt16HostToBig(x)
#define S32(x) CFSwapInt32HostToBig(x)
#define S64(x) CFSwapInt64HostToBig(x)

#endif /* ImpByteOrder_h */
