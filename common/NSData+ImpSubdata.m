//
//  NSData+ImpSubdata.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-04.
//

#import "NSData+ImpSubdata.h"

@interface ImpDataSlice : NSMutableData

- (instancetype _Nonnull)initWithMutableData:(NSMutableData *)data range:(NSRange)range;

@end

@implementation NSData (ImpSubdata)

///This method exists to show up in call stacks when you get an NSRangeException under a call to withRange:showSubdataToBlock_Imp:.
- (void) throwRangeExceptionForRange_Imp:(NSRange)range {
	//Call through to subdataWithRange: and let it throw the exception, so we don't have to replicate what it does.
	[self subdataWithRange:range];
}

- (void) withRange:(NSRange)range
	showSubdataToBlock_Imp:(void (^_Nonnull const)(void const *_Nonnull bytes, NSUInteger length))block
{
	void const *_Nonnull const ourBytes = self.bytes;
	NSUInteger const ourLength = self.length;

	//If the range starts off the end of the data, or we're not long enough to provide all those bytes…
	if (range.location > ourLength || ourLength - range.location < range.length) {
		[self throwRangeExceptionForRange_Imp:range];
	}

	void const *_Nonnull const offsetBytes = ourBytes + range.location;
	NSUInteger const offsetLength = ourLength - range.length;
	block(offsetBytes, offsetLength);
}

///Implementation method for dangerouslyFast{,Mutable}SubdataWithRange:. dataClass must be NSData or some subclass of it.
- (NSData *_Nonnull) dangerouslyFastSubdataWithRange_Imp:(NSRange)range
	bytesPointer:(void *_Nonnull const)ourBytes
	dataClass:(Class _Nonnull const)dataClass
{
	NSUInteger const ourLength = self.length;

	if (range.location > ourLength || ourLength - range.location < range.length) {
		[self throwRangeExceptionForRange_Imp:range];
	}

	void const *_Nonnull const offsetBytes = ourBytes + range.location;
	NSUInteger const offsetLength = MIN(ourLength - range.location, range.length);

	NSData *_Nonnull const subdata = [[dataClass alloc] initWithBytesNoCopy:(void *)offsetBytes length:offsetLength freeWhenDone:false];
	return subdata;
}
- (NSData *_Nonnull) dangerouslyFastSubdataWithRange_Imp:(NSRange)range {
	return [self dangerouslyFastSubdataWithRange_Imp:range bytesPointer:(void *_Nonnull const)self.bytes dataClass:[NSData class]];
}
- (NSMutableData *_Nonnull) dangerouslyFastMutableSubdataWithRange_Imp:(NSRange)range {
	return [[ImpDataSlice alloc] initWithMutableData:(NSMutableData *)self range:range];
}

@end

@implementation ImpDataSlice
{
	void *_Nonnull _bytesPointer;
	NSUInteger _originalLength;
	NSUInteger _length;
}

- (instancetype _Nonnull) initWithMutableData:(NSMutableData *)data range:(NSRange)range {
	_bytesPointer = data.mutableBytes + range.location;
	_originalLength = range.length;
	_length = _originalLength;
	return self;
}

- (void const *_Nonnull) bytes NS_RETURNS_INNER_POINTER {
	return self.mutableBytes;
}
- (void *_Nonnull) mutableBytes NS_RETURNS_INNER_POINTER {
	return _bytesPointer;
}

- (NSUInteger) length {
	return _length;
}
- (void) setLength:(NSUInteger)length {
	NSAssert(length <= _originalLength, @"Cannot resize a data that is a slice of a larger data to a size that is greater than the range it was created from (original length %lu; current length %lu; proposed new length %lu)", _originalLength, _length, length);
	if (length > _length) {
		NSRange const zeroThisPart = { _length, _length - length };
		bzero(_bytesPointer + zeroThisPart.location, zeroThisPart.length);
	}
	_length = length;
}

@end
