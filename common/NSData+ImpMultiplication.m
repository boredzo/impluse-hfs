//
//  NSData+ImpMultiplication.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-02-15.
//

#import "NSData+ImpMultiplication.h"

#import <os/overflow.h>

@implementation NSData (ImpMultiplication)

- (NSData *_Nonnull const) times_Imp:(NSUInteger)multiplier {
	NSUInteger numBytes = 0;
	bool const overflows = os_mul_overflow(self.length, multiplier, &numBytes);
	NSAssert(! overflows, @"Can't multiply data of size %lu by %lu times: Product would be too many bytes", self.length, multiplier);
	NSMutableData *_Nonnull const result = [NSMutableData dataWithCapacity:numBytes];
	for (NSUInteger i = 0; i < multiplier; ++i) {
		[result appendData:self];
	}
	return result;
}

@end
