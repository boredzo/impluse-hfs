//
//  ImpBTreeIndexNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#import "ImpBTreeIndexNode.h"

#import "ImpByteOrder.h"
#import "ImpBTreeFile.h"

@implementation ImpBTreeIndexNode
{
	NSArray <ImpBTreeNode *> *_Nullable _children;
}

- (NSArray <ImpBTreeNode *> *_Nonnull const) children {
	if (_children == nil) {
		NSMutableArray *_Nonnull const children = [NSMutableArray arrayWithCapacity:self.numberOfRecords];

		ImpBTreeFile *_Nonnull const tree = self.tree;
		[self forEachRecord:^bool(NSData *_Nonnull const data) {
			void const *_Nonnull const ptr = data.bytes;
			u_int32_t const *_Nonnull const nodeIndexPtr = (ptr + data.length - sizeof(u_int32_t));
			u_int32_t idx = L(*nodeIndexPtr);
			ImpBTreeNode *_Nonnull newChild = [tree nodeAtIndex:idx];
			[children addObject:newChild];
			return true;
		}];

		_children = children;
	}

	return _children;
}

- (ImpBTreeNode *_Nullable) descendWithKeyComparator:(ImpBTreeComparisonResult (^_Nonnull const)(void const *_Nonnull const keyPtr))block {
	__block ImpBTreeNode *_Nullable result = nil;
	__block bool foundBestMatch = false;

	[self forEachRecord:^bool(NSData *const  _Nonnull data) {
		void const *_Nonnull const recordPtr = data.bytes;
		void const *_Nonnull const keyPtr = recordPtr;
		//TODO: This assumes this is an HFS B*-tree. In HFS+, key lengths are two bytes. Which size we use needs to be configurable.
		u_int8_t const *_Nonnull const hfsKeyLengthPtr = recordPtr;
		static u_int16_t const hfsKeyLengthSize = sizeof(u_int8_t);
		u_int16_t const keyLength = (*hfsKeyLengthPtr) + hfsKeyLengthSize;
		u_int32_t const *_Nonnull const downwardNodePtr = (u_int32_t const *)(recordPtr + keyLength);

		ImpBTreeComparisonResult order = block(keyPtr);
		bool keepIterating = true;
		switch (order) {
			case ImpBTreeComparisonQuarryIsEqual:
				//Hooray, an exact match! Descend directly to this node.
				result = [self.tree nodeAtIndex:L(*downwardNodePtr)];
				foundBestMatch = true;
				keepIterating = false;
				break;

			case ImpBTreeComparisonQuarryIsGreater:
				//Not an exact match yet (if there even is one), but we're still in the range of eligible keys (we're searching for either an exact match or the greatest key that's less than the quarry). So this is the new greatest candidate so far, but we're not yet ready to stop the search.
				result = [self.tree nodeAtIndex:L(*downwardNodePtr)];
				break;

			case ImpBTreeComparisonQuarryIsLesser:
				//We've found a key that is greater than the quarry, so we've run out of eligible candidates. Stop iterating and descend to the last result we got.
				keepIterating = false;
				break;

			case ImpBTreeComparisonQuarryIsIncomparable:
			default:
				//Well, bummer. There's at least one key here that the comparator didn't recognize. This might indicate the reading or parsing got off-track, or the volume is actually corrupt.
				//TODO: This cries out for better reporting, both of content (which file were we searching? where was the bad key detected? what were we searching for?) and of venue (how are we going to report this in a GUI?).
				ImpPrintf(@"WARNING: Incomparable key detected during search. This may be a bug or it may indicate volume corruption.");
				break;
		}
		return keepIterating;
	}];

	if (! foundBestMatch) {
		ImpBTreeIndexNode *_Nonnull const nextIndexNode = (ImpBTreeIndexNode *_Nonnull const)self.nextNode;
		ImpBTreeNode *_Nonnull const possiblyBetterCandidate = [nextIndexNode descendWithKeyComparator:block];
		if (possiblyBetterCandidate != nil) {
			result = possiblyBetterCandidate;
		}
	}

	return result;
}

@end
