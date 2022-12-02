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

@property(readonly) ImpBTreeNode *_Nullable nextNode;

- (NSData *_Nonnull) recordDataAtIndex:(u_int16_t)idx;

///Call this block for every record in this node.
- (void) forEachRecord:(void (^_Nonnull const)(NSData *_Nonnull const data))block;

///Call these blocks with every catalog record in this B*-tree node, assuming that this B*-tree node is in a catalog file. Behavior is undefined if you call this on a node that isn't in a catalog file, such as an extents overflow file.
- (void) forEachCatalogRecord_file:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFile const *_Nonnull const))fileRecordBlock
	folder:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogFolder const *_Nonnull const))folderRecordBlock
	thread:(void (^_Nonnull const)(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, struct HFSCatalogThread const *_Nonnull const))threadRecordBlock;

@end
