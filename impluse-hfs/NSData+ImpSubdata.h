//
//  NSData+ImpSubdata.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-04.
//

#import <Foundation/Foundation.h>

@interface NSData (ImpSubdata)

///subdataWithRange: has to create an NSData wrapping the given range, and (it turns out) also copies the indicated bytes to a new backing store, even when it doesn't need to. Sigh. This method solves both of those problems. It calls the block with the bytes pointer and length that such a subdata would have, without creating any such object or copying any bytes. Treat the bytes pointer as if it has a neon NS_RETURNS_INNER_POINTER flashing above it.
- (void) withRange:(NSRange)range
	showSubdataToBlock_Imp:(void (^_Nonnull const)(void const *_Nonnull bytes, NSUInteger length))block;

///subdataWithRange: copies the backing store even when it doesn't need to. This method borrows the backing store of the parent data, which is dangerous if the subdata might outlive its parent.
- (NSData *_Nonnull) dangerouslyFastSubdataWithRange_Imp:(NSRange)range;

@end

