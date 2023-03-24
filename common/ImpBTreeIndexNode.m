//
//  ImpBTreeIndexNode.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#import "ImpBTreeIndexNode.h"

#import "ImpByteOrder.h"
#import "ImpPrintf.h"
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

	ImpBTreeFile *_Nullable const tree = self.tree;

	bool isHFSPlus = false;
	switch (tree.version) {
		case ImpBTreeVersionHFSPlusCatalog:
		case ImpBTreeVersionHFSPlusExtentsOverflow:
		case ImpBTreeVersionHFSPlusAttributes:
			isHFSPlus = true;
			break;

		case ImpBTreeVersionHFSCatalog:
		case ImpBTreeVersionHFSExtentsOverflow:
		default:
			isHFSPlus = false;
			break;
	}

	[self forEachRecord:^bool(NSData *const  _Nonnull data) {
		void const *_Nonnull const recordPtr = data.bytes;
		void const *_Nonnull const keyPtr = recordPtr;

		u_int8_t const *_Nonnull const hfsKeyLengthPtr = recordPtr;
		u_int16_t const *_Nonnull const hfsPlusKeyLengthPtr = recordPtr;

		u_int16_t const keyLengthSize = self.tree.keyLengthSize;
		u_int16_t const keyLength = keyLengthSize == sizeof(u_int16_t)
			? L(*hfsPlusKeyLengthPtr) + keyLengthSize
			:  (*hfsKeyLengthPtr) + keyLengthSize;
		u_int32_t const *_Nonnull const downwardNodePtr = (u_int32_t const *)(recordPtr + keyLength);

		ImpBTreeComparisonResult order = block(keyPtr);
		bool keepIterating = true;
		switch (order) {
			case ImpBTreeComparisonQuarryIsEqual:
				//Hooray, an exact match! Descend directly to this node.
				result = [tree nodeAtIndex:L(*downwardNodePtr)];
				foundBestMatch = true;
				keepIterating = false;
				break;

			case ImpBTreeComparisonQuarryIsGreater:
				//Not an exact match yet (if there even is one), but we're still in the range of eligible keys (we're searching for either an exact match or the greatest key that's less than the quarry). So this is the new greatest candidate so far, but we're not yet ready to stop the search.
				result = [tree nodeAtIndex:L(*downwardNodePtr)];
				break;

			case ImpBTreeComparisonQuarryIsLesser:
				//We've found a key that is greater than the quarry, so we've run out of eligible candidates. Stop iterating and descend to the last result we got.
				foundBestMatch = true;
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
		//At this point, it might be tempting to look in sibling nodes.
		//But we've already been selected by searchSiblingsForBestMatchingNodeWithComparator:. This *is* the node to descend from. If we've gotten to this point, every single record in *this* node is viable, but the first record in the *next* node—if there is one—is not (because if it were, searchSiblings would have returned that node).
		//So, stay in this node and descend through our last record.
		NSAssert(result != nil, @"Expected to have found a viable match here (was the catalog file empty?); node contains %u records", self.numberOfRecords);
	}

	return result;
}

@end
