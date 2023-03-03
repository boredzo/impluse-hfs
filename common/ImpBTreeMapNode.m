//
//  ImpBTreeMapNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-18.
//

#import "ImpBTreeMapNode.h"

@implementation ImpBTreeMapNode
{
	CFMutableBitVectorRef _bitVector;
}

- (u_int16_t) mapRecordIndex  {
	return 0;
}

- (NSUInteger)numberOfBits {
	return [self recordDataAtIndex:self.mapRecordIndex].length * 8;
}

///Load the map record bits from the node's backing data into a CFMutableBitVector to enable alterations to the map record.
- (void) loadBitVector {
	if (_bitVector == NULL) {
		NSData *_Nonnull const mapRecordData = [self recordDataAtIndex:self.mapRecordIndex];
		NSUInteger const numberOfBits = mapRecordData.length * 8;
		CFBitVectorRef _Nonnull const tempBitVector = CFBitVectorCreate(kCFAllocatorDefault, mapRecordData.bytes, numberOfBits);
		_bitVector = CFBitVectorCreateMutableCopy(kCFAllocatorDefault, numberOfBits, tempBitVector);
		CFRelease(tempBitVector);
	}
}
///Store the map record bits from the CFMutableBitVector back to the backing data.
- (void) storeBitVector {
	if (_bitVector != nil) {
		NSMutableData *_Nonnull const mapRecordData = [self mutableRecordDataAtIndex:self.mapRecordIndex];
		CFRange const range = { 0, mapRecordData.length * 8 };
		CFBitVectorGetBits(_bitVector, range, mapRecordData.mutableBytes);
	} else {
		//If we haven't created a bit vector, then we haven't made any changes that need to be flushed, so leave the existing map record data alone.
	}
}

- (NSComparisonResult) containsBitIndex:(NSUInteger)absIdx {
	NSRange const range = { self.firstRelativeIndex, self.numberOfBits };
	if (absIdx < range.location) {
		return NSOrderedAscending;
	} else if (absIdx >= NSMaxRange(range)) {
		return NSOrderedDescending;
	} else {
		return NSOrderedSame;
	}
}
///Note that the returned node may be an ImpBTreeHeaderNode, not an ImpBTreeMapNode.
- (ImpBTreeMapNode *_Nullable const) nodeContainingBitIndex:(NSUInteger)absIdx {
	NSComparisonResult const direction = [self containsBitIndex:absIdx];
	switch (direction) {
		case NSOrderedSame:
			return self;
		case NSOrderedAscending:
			return (ImpBTreeMapNode *_Nullable const)self.previousNode;
		case NSOrderedDescending:
			return (ImpBTreeMapNode *_Nullable const)self.nextNode;
	}
	return nil;
}

- (bool) isNodeAllocated:(NSUInteger)absIdx {
	ImpBTreeMapNode *_Nullable const closerNode = [self nodeContainingBitIndex:absIdx];
	if (closerNode == self) {
		return [self testBitAtRelativeIndex:absIdx - self.firstRelativeIndex];
	} else {
		return [closerNode isNodeAllocated:absIdx];
	}
}

- (bool) testBitAtRelativeIndex:(NSUInteger)idx {
	[self loadBitVector];
	return CFBitVectorGetBitAtIndex(_bitVector, idx);
}

- (void) setBitAtRelativeIndex:(NSUInteger)idx toValue:(bool)value {
	[self loadBitVector];
	CFBitVectorSetBitAtIndex(_bitVector, idx, value);
	[self storeBitVector];
}

- (void) allocateNode:(NSUInteger)absIdx {
	ImpBTreeMapNode *_Nullable const closerNode = [self nodeContainingBitIndex:absIdx];
	if (closerNode == self) {
		[self setBitAtRelativeIndex:absIdx - self.firstRelativeIndex toValue:true];
	} else {
		[closerNode allocateNode:absIdx];
	}
}
- (void) deallocateNode:(NSUInteger)absIdx {
	ImpBTreeMapNode *_Nullable const closerNode = [self nodeContainingBitIndex:absIdx];
	if (closerNode == self) {
		[self setBitAtRelativeIndex:absIdx - self.firstRelativeIndex toValue:false];
	} else {
		[closerNode deallocateNode:absIdx];
	}
}

@end
