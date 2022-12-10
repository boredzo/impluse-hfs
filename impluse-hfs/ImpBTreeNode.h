//
//  ImpBTreeNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import <Foundation/Foundation.h>

enum {
	BTreeNodeLengthStandard = 512,
	BTreeNodeLengthExtended = 4096,
};

///See Inside Macintosh: Files page 2-65 for info on how B*-tree nodes are lain out.
struct BTreeNode {
	struct BTNodeDescriptor header;
	//TODO: Variable-length array to end this structure? Need to carry node length separately anyway, if these classes are to be used for both HFS and HFS+…
	char payload[BTreeNodeLengthStandard - sizeof(struct BTNodeDescriptor)];
};
struct BTreeNodeExtended {
	struct BTNodeDescriptor header;
	char payload[BTreeNodeLengthExtended - sizeof(struct BTNodeDescriptor)];
};

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

@class ImpBTreeFile;

@interface ImpBTreeNode : NSObject

///May return an instance of a subclass, such as ImpBTreeHeaderNode. Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
+ (instancetype _Nullable) nodeWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData;

///Tree is used to convert inter-node references such as firstLeafNode into pointers to node objects.
- (instancetype _Nullable)initWithTree:(ImpBTreeFile *_Nonnull const)tree data:(NSData *_Nonnull const)nodeData;

@property(readonly, weak) ImpBTreeFile *_Nullable tree;
///The range within the original B*-tree file from which this node was instantiated. location must always be a multiple of 512, and length must always be 512 (or 4096 in HFS+).
@property(readwrite) NSRange byteRange;

@property(readwrite) u_int32_t nodeNumber;
@property(readonly) u_int32_t forwardLink, backwardLink;
@property(readonly) int8_t nodeType;
@property(readonly) NSString *_Nonnull nodeTypeName;
@property(readonly) u_int8_t nodeHeight;
@property(readonly) u_int16_t numberOfRecords;

@property(nonatomic, readonly) ImpBTreeNode *_Nullable previousNode;
@property(nonatomic, readonly) ImpBTreeNode *_Nullable nextNode;

///Given a comparator block, search the siblings *only* of this node for the best-matching node. It may be an index node, in which case descent and further searching may be required to find the leaf node that will either have an exact match or not.
///The best-matching node is the one with the greatest record that is less than or equal to the quarry. How each record in these nodes compares to the quarry is for the comparator block to determine.
///May return nil if this node contains no records, or contains no comparable records.
- (ImpBTreeNode *_Nullable) searchSiblingsForBestMatchingNodeWithComparator:(ImpBTreeRecordKeyComparator _Nonnull)comparator;

///Search this node for the record with the greatest key that is less than or equal to the quarry. Returns its index. Returns -1 if the first key in this node is greater than the quarry.
- (int16_t) indexOfBestMatchingRecord:(ImpBTreeRecordKeyComparator _Nonnull)comparator;

#pragma mark Records

///Returns the whole catalog record, key and payload, at the given index within the node.
- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx;

///Returns only the key from this record. This data is a prefix of the corresponding recordDataAtIndex:. Returns nil if this node is not an index or leaf node. (Header and map nodes don't have key-value records.)
- (NSData *_Nullable) recordKeyDataAtIndex:(u_int16_t)idx;

///Returns only the payload from this record. This data is a suffix of the corresponding recordDataAtIndex:. Returns nil if this node is not an index or leaf node. (Header and map nodes don't have key-value records.)
- (NSData *_Nullable) recordPayloadDataAtIndex:(u_int16_t)idx;

///Call this block for every record in this node. Stops iterating if the block returns false. Returns the number of records visited (which may be less than the number of records in the node, if the block called an early stop).
- (NSUInteger) forEachRecord:(bool (^_Nonnull const)(NSData *_Nonnull const data))block;

///Call this block for every record in this node. Stops iterating if the block returns false. Returns the number of records visited (which may be less than the number of records in the node, if the block called an early stop).
- (NSUInteger) forEachKeyedRecord:(bool (^_Nonnull const)(NSData *_Nonnull const keyData, NSData *_Nonnull const payloadData))block;

///Call these blocks with every catalog record in this B*-tree node, assuming that this B*-tree node is in a catalog file. Behavior is undefined if you call this on a node that isn't in a catalog file, such as an extents overflow file.
- (void) forEachCatalogRecord_file:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const))fileRecordBlock
	folder:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock;

@end
