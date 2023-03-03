//
//  ImpComparisonUtilities.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(int8_t, ImpBTreeComparisonResult) {
	///The key being searched for is less than (should come before) the key found in a node.
	ImpBTreeComparisonQuarryIsLesser = -1,
	///The key being searched for is an exact match to the key found in a node.
	ImpBTreeComparisonQuarryIsEqual = 0,
	///The key being searched for is greater than (should come after) the key found in a node.
	ImpBTreeComparisonQuarryIsGreater = +1,
	///Comparator blocks should return Incomparable when two keys have different keyLengths, or otherwise cannot be meaningfully said to have an order relationship between them.
	ImpBTreeComparisonQuarryIsIncomparable = 86,
};

///Block that takes a pointer to a key from a record in a B*-tree index node (the found key), and returns how it compares to some other key (the quarry). The block is expected to know via capture what it is looking for.
typedef ImpBTreeComparisonResult (^ImpBTreeRecordKeyComparator)(void const *_Nonnull const foundKeyPtr);

ImpBTreeComparisonResult ImpBTreeCompareHFSCatalogKeys(struct HFSCatalogKey const *_Nonnull const a, struct HFSCatalogKey const *_Nonnull const b);
ImpBTreeComparisonResult ImpBTreeCompareHFSPlusCatalogKeys(struct HFSPlusCatalogKey const *_Nonnull const a, struct HFSPlusCatalogKey const *_Nonnull const b);

///Implements the case-insensitive Unicode string comparison algorithm defined by TN1150, “HFS Plus Volume Format”.
NSComparisonResult ImpHFSPlusCompareNames(struct HFSUniStr255 const *_Nonnull const str0, struct HFSUniStr255 const *_Nonnull const str1);
