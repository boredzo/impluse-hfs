//
//  NSData+ImpSubdata.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-04.
//

#import "NSData+ImpSubdata.h"

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

- (NSData *_Nonnull) dangerouslyFastSubdataWithRange_Imp:(NSRange)range {
	void const *_Nonnull const ourBytes = CFDataGetBytePtr((__bridge CFDataRef)self);
	NSUInteger const ourLength = self.length;

	if (range.location > ourLength || ourLength - range.location < range.length) {
		[self throwRangeExceptionForRange_Imp:range];
	}

	void const *_Nonnull const offsetBytes = ourBytes + range.location;
	NSUInteger const offsetLength = MIN(ourLength - range.location, range.length);

	NSData *_Nonnull const subdata = [[NSData alloc] initWithBytesNoCopy:(void *)offsetBytes length:offsetLength freeWhenDone:false];
	return subdata;
}

@end
