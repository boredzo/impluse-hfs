//
//  ImpCatalogBuilder.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-06.
//

#import "ImpCatalogBuilder.h"

#import "ImpTextEncodingConverter.h"
#import "ImpBTreeFile.h"
#import "ImpMutableBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

#pragma mark Prologue: Interfaces of the helper classes

///Identifier object for an item on a volume.
///Why not just use the CNID? Because some HFS volumes reuse CNIDs. Technically this is invalid, but hardly any consistency checkers catch it, including Apple's own Disk First Aid and fsck_hfs!!
@interface ImpCatalogItemIdentifier : NSObject <NSCopying>

+ (instancetype) identifierWithParentCNID:(HFSCatalogNodeID const)parentID ownCNID:(HFSCatalogNodeID const)ownID nodeName:(NSString *_Nonnull const)nodeName;
+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData fileRecordData:(NSData *_Nonnull const)fileRecData;
+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData folderRecordData:(NSData *_Nonnull const)folderRecData;
+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData threadRecordData:(NSData *_Nonnull const)threadRecData;
+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData fileRecordData:(NSData *_Nonnull const)fileRecData;
+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData folderRecordData:(NSData *_Nonnull const)folderRecData;
+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData threadRecordData:(NSData *_Nonnull const)threadRecData;

@property(readonly) HFSCatalogNodeID parentID;
@property(readonly) HFSCatalogNodeID ownID;
@property(readonly, copy) NSString *_Nonnull nodeName;
@property(readwrite, copy) NSString *_Nonnull typeEmoji;

@end

///Simple data object representing one key-value pair in a B*-tree file's leaf row. Used in converting the catalog file (as thread records may need to be created for files that don't have them, and these thread records will need to be inserted into the list of records in a way that preserves the ordering of keys).
@interface ImpCatalogKeyValuePair : NSObject

- (instancetype _Nonnull)initWithKey:(NSData *_Nonnull const)keyData value:(NSData *_Nonnull const)valueData;

@property(strong) NSData *key;
@property(strong) NSData *value;

@end

@interface ImpCatalogItem ()

@property(readwrite, strong) ImpCatalogItemIdentifier *_Nonnull identifier;

@end

///Pared-down substitute for ImpBTreeNode, which needs to be backed by a complete tree. This is used in making a new tree.
@interface ImpMockNode : NSObject

///Create an ImpMockNode that can hold maxNumBytes' worth of records.
- (instancetype) initWithCapacity:(u_int32_t const)maxNumBytes;

///The index of this node, starting from 0. This node should never be given the index 0 (and, since it defaults to 0, it must be changed) since that's the index of the header node, and ImpMockNodes never represent a header node.
@property u_int32_t nodeNumber;

///The height of this row in the B*-tree. The header row (header node and map nodes) has no height; nodes in that row have height 0. The leaf row is always at height 1, and index rows are at increasing heights above that.
@property u_int8_t nodeHeight;

///The first key that has been added to this node, if any. (Used for building index nodes from the first key of each node on the row below.)
@property(nonatomic, readonly) NSData *_Nullable firstKey;

///Returns the total size of all records in the node (that is, all keys plus all associated payloads).
@property(readonly) u_int32_t totalSizeOfAllRecords;

///Append a key to the node's list of records.
- (bool) appendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData;

- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode;

@end
@interface ImpMockIndexNode : ImpMockNode

///Append a key to the node's list of pointer records, linked to the provided node.
- (bool) appendKey:(NSData *_Nonnull const)keyData fromNode:(ImpMockNode *_Nonnull const)descendantNode;

///Add records to a real index node to match the contents of this mock index node.
- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode;

@end

static u_int16_t ImpGetCatalogKeyType(NSData *_Nonnull const keyData) {
	if (keyData.length < sizeof(u_int16_t)) {
		return 0;
	}

	u_int16_t const *_Nonnull const keyTypePtr = keyData.bytes;
	return L(*keyTypePtr);
}

static ImpBTreeVersion ImpGetCatalogKeyVersion(NSData *_Nonnull const keyData) {
	enum {
		ImpHFSCatalogKeyTypesMask = 0xff00,
		ImpHFSPlusCatalogKeyTypesMask = 0xff,
	};
	if (ImpGetCatalogKeyType(keyData) & ImpHFSCatalogKeyTypesMask) {
		return ImpBTreeVersionHFSCatalog;
	} else if (ImpGetCatalogKeyType(keyData) & ImpHFSPlusCatalogKeyTypesMask) {
		return ImpBTreeVersionHFSPlusCatalog;
	}
	return 0;
}

#pragma mark -
#pragma mark And now, the actual implementation

@interface ImpCatalogBuilder ()

@property(readonly) ImpBTreeVersion version;
@property(readwrite) HFSCatalogNodeID nextCatalogNodeID;
@property(readwrite) bool hasReusedCatalogNodeIDs;

- (void) buildMockTree;
- (void) invalidateMockTree;

@end

@implementation ImpCatalogBuilder
{
	NSMutableDictionary <ImpCatalogItemIdentifier *, ImpCatalogItem *> *_Nonnull _sourceItemsByIdentifier;
	NSMutableSet <ImpCatalogItem *> *_Nonnull _sourceItemsThatNeedThreadRecords;
	NSMutableArray <ImpCatalogItem *> *_Nonnull _allSourceItems;

	NSMutableArray <NSArray <ImpMockNode *> *> *_Nonnull _mockRows;
	NSMutableArray <ImpMockIndexNode *> *_Nonnull _allMockIndexNodes;
	NSMutableArray <ImpCatalogKeyValuePair *> *_Nonnull _allKeyValuePairs;

	ImpBTreeVersion _version;
	__block HFSCatalogNodeID _largestCNIDYet;
	__block HFSCatalogNodeID _firstUnusedCNID;
	u_int32_t _numLiveNodes;
	u_int16_t _nodeSize;
	bool _treeIsBuilt;
}

- (instancetype _Nullable) initWithBTreeVersion:(ImpBTreeVersion const)version
	bytesPerNode:(u_int16_t const)nodeSize
	expectedNumberOfItems:(NSUInteger const)numItems
{
	if (version != ImpBTreeVersionHFSCatalog && version != ImpBTreeVersionHFSPlusCatalog) {
		self = nil;
	} else if ((self = [super init])) {
		_sourceItemsByIdentifier = [NSMutableDictionary dictionaryWithCapacity:numItems];
		_sourceItemsThatNeedThreadRecords = [NSMutableSet setWithCapacity:numItems];
		_allSourceItems = [NSMutableArray arrayWithCapacity:numItems];

		//_mockRows, _allMockIndexNodes, and _allKeyValuePairs are created during buildMockTree.

		_version = version;
		_nodeSize = nodeSize;
		_largestCNIDYet = 0;
		_firstUnusedCNID = 0;
	}
	return self;
}

- (void) updateCNIDBoundaries:(HFSCatalogNodeID)foundCNID {
	if (foundCNID > _largestCNIDYet) {
		_largestCNIDYet = foundCNID;
		if (_firstUnusedCNID == 0 && foundCNID - 1 > _largestCNIDYet) {
			_firstUnusedCNID = _largestCNIDYet + 1;
		}
	}
}

- (ImpCatalogItem *_Nonnull const) addKey:(NSMutableData *_Nonnull const)keyData fileRecord:(NSMutableData *_Nonnull const)payloadData {
	[self invalidateMockTree];

	void const *_Nonnull const payloadPtr = payloadData.bytes;
	if (self.version == ImpBTreeVersionHFSCatalog) {
		struct HFSCatalogFile const *_Nonnull const fileRecPtr = payloadPtr;
		[self updateCNIDBoundaries:L(fileRecPtr->fileID)];
	} else if (self.version == ImpBTreeVersionHFSPlusCatalog) {
		struct HFSPlusCatalogFile const *_Nonnull const fileRecPtr = payloadPtr;
		[self updateCNIDBoundaries:L(fileRecPtr->fileID)];
	}

	ImpCatalogItemIdentifier *_Nonnull const identifier = [ImpCatalogItemIdentifier identifierWithHFSPlusCatalogKeyData:keyData fileRecordData:payloadData];

	ImpCatalogItem *_Nullable item = _sourceItemsByIdentifier[identifier];
	if (item != nil){
//		ImpPrintf(@"📄 Found existing item for %@: %@", identifier, item);
	}else {
		item = [[ImpCatalogItem alloc] initWithIdentifier:identifier];
		_sourceItemsByIdentifier[identifier] = item;
		[_allSourceItems addObject:item];
		[_sourceItemsThatNeedThreadRecords addObject:item];
//		ImpPrintf(@"📄 Created item for %@: %@", identifier, item);
	}

	item.destinationKey = keyData;
	item.destinationRecord = payloadData;
//	ImpPrintf(@"📄 Item is updated: %@", item);

	return item;
}

- (ImpCatalogItem *_Nonnull const) addKey:(NSMutableData *_Nonnull const)keyData folderRecord:(NSMutableData *_Nonnull const)payloadData {
	[self invalidateMockTree];

	void const *_Nonnull const payloadPtr = payloadData.bytes;
	if (self.version == ImpBTreeVersionHFSCatalog) {
		struct HFSCatalogFolder const *_Nonnull const folderRecPtr = payloadPtr;
		[self updateCNIDBoundaries:L(folderRecPtr->folderID)];
	} else if (self.version == ImpBTreeVersionHFSPlusCatalog) {
		struct HFSPlusCatalogFolder const *_Nonnull const folderRecPtr = payloadPtr;
		[self updateCNIDBoundaries:L(folderRecPtr->folderID)];
	}

	ImpCatalogItemIdentifier *_Nonnull const identifier = [ImpCatalogItemIdentifier identifierWithHFSPlusCatalogKeyData:keyData folderRecordData:payloadData];

	ImpCatalogItem *_Nullable item = _sourceItemsByIdentifier[identifier];
	if (item != nil){
//		ImpPrintf(@"📁 Found existing item for %@: %@", identifier, item);
	} else {
		item = [[ImpCatalogItem alloc] initWithIdentifier:identifier];
		_sourceItemsByIdentifier[identifier] = item;
		[_allSourceItems addObject:item];
		[_sourceItemsThatNeedThreadRecords addObject:item];
//		ImpPrintf(@"📁 Created item for %@: %@", identifier, item);
	}

	item.destinationKey = keyData;
	item.destinationRecord = payloadData;
//	ImpPrintf(@"📁 Item is updated: %@", item);

	return item;
}

- (ImpCatalogItem *_Nonnull const) addKey:(NSMutableData *_Nonnull const)keyData threadRecord:(NSMutableData *_Nonnull const)payloadData {
	[self invalidateMockTree];

	void const *_Nonnull const keyPtr = keyData.bytes;
	if (self.version == ImpBTreeVersionHFSCatalog) {
		struct HFSCatalogKey const *_Nonnull const catalogKeyPtr = keyPtr;
		HFSCatalogNodeID const cnid = L(catalogKeyPtr->parentID);
		if (cnid > _largestCNIDYet) _largestCNIDYet = cnid;
	} else if (self.version == ImpBTreeVersionHFSPlusCatalog) {
		struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr = keyPtr;
		HFSCatalogNodeID const cnid = L(catalogKeyPtr->parentID);
		if (cnid > _largestCNIDYet) _largestCNIDYet = cnid;
	}

	ImpCatalogItemIdentifier *_Nonnull const identifier = [ImpCatalogItemIdentifier identifierWithHFSPlusCatalogKeyData:keyData threadRecordData:payloadData];

	ImpCatalogItem *_Nullable item = _sourceItemsByIdentifier[identifier];
	if (item == nil) {
		item = [[ImpCatalogItem alloc] initWithIdentifier:identifier];
		_sourceItemsByIdentifier[identifier] = item;
		[_allSourceItems addObject:item];
//		ImpPrintf(@"🧵 Created item for %@: %@", identifier, item);
	} else {
//		ImpPrintf(@"🧵 Thread-ified item for %@: %@", identifier, item);
		[_sourceItemsThatNeedThreadRecords removeObject:item];
	}

	item.destinationThreadKey = keyData;
	item.destinationThreadRecord = payloadData;
	item.needsThreadRecord = false;
//	ImpPrintf(@"🧵 Item is updated: %@", item);

	return item;
}

- (void) fillInHFSThreadRecords {
	//For archiving to HFS: The archiver is feeding in file and folder records, so no thread records at all exist, so we need to create all of them here.
	for (ImpCatalogItem *_Nonnull const item in _sourceItemsThatNeedThreadRecords) {
		NSData *_Nonnull const keyData = item.destinationKey;
		struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
//		ImpPrintf(@"Item %p “%@” needs thread record: %@", item, [ImpBTreeNode describeHFSCatalogKeyWithData:keyData], item.needsThreadRecord ? @"YES" : @"NO");
		if (item.needsThreadRecord) {
			NSMutableData *_Nonnull const threadKeyData = [NSMutableData dataWithLength:sizeof(struct HFSCatalogKey)];
			struct HFSCatalogKey *_Nonnull const threadKeyPtr = threadKeyData.mutableBytes;
			NSMutableData *_Nonnull const threadRecData = [NSMutableData dataWithLength:sizeof(struct HFSCatalogThread)];
			struct HFSCatalogThread *_Nonnull const threadRecPtr = threadRecData.mutableBytes;

			NSMutableData *_Nonnull const recData = item.destinationRecord;
			void *_Nonnull const recPtr = recData.mutableBytes;
			int16_t const *_Nonnull const recTypePtr = recPtr;
			struct HFSCatalogFile *_Nonnull const filePtr = recPtr;
			struct HFSCatalogFolder *_Nonnull const folderPtr = recPtr;

			//In a thread record, the key holds the item's *own* ID (despite being called “parentID”) and an empty name, while the thread record holds the item's *parent*'s ID and the item's own name.
			switch (L(*recTypePtr)) {
				case kHFSFileRecord:
					threadKeyPtr->parentID = filePtr->fileID;
					S(threadRecPtr->recordType, kHFSFileThreadRecord);
					S(filePtr->flags, L(filePtr->flags) | kHFSThreadExistsMask);
					break;
				case kHFSFolderRecord:
					//Technically we shouldn't get here, either, as thread records were required for folders under HFS.
					threadKeyPtr->parentID = folderPtr->folderID;
					S(threadRecPtr->recordType, kHFSFolderThreadRecord);
					S(folderPtr->flags, L(folderPtr->flags) | kHFSThreadExistsMask);
					break;
				default:
					__builtin_unreachable();
			}
			threadRecPtr->parentID = keyPtr->parentID;
			memcpy(&threadRecPtr->nodeName, &keyPtr->nodeName, sizeof(threadRecPtr->nodeName));
			//DiskWarrior complains about “oversized thread records” if the thread payload contains empty space. Plus, shrinking these down frees up space in the node for more records.
			u_int32_t const threadRecSize = sizeof(threadRecPtr->recordType) + sizeof(threadRecPtr->reserved) + sizeof(threadRecPtr->parentID) + sizeof(threadRecPtr->nodeName[0]) + sizeof(unsigned char) * L(threadRecPtr->nodeName[0]);
			[threadRecData setLength:threadRecSize];

			//A thread key has a CNID and an empty node name (so, length 0). keyLength doesn't include itself.
			u_int16_t const threadKeySize = sizeof(threadKeyPtr->keyLength) + sizeof(threadKeyPtr->parentID) + sizeof(threadKeyPtr->nodeName[0]);
			u_int16_t const threadKeyLength = threadKeySize - sizeof(threadKeyPtr->keyLength);
			S(threadKeyPtr->keyLength, threadKeyLength);
			[threadKeyData setLength:threadKeySize];

			item.destinationThreadKey = threadKeyData;
			item.destinationThreadRecord = threadRecData;
			item.needsThreadRecord = false;
		}
	}

}
- (void) fillInHFSPlusThreadRecords {
	//For conversion from HFS to HFS+: HFS requires folders to have thread records, so those should all have them, but files having thread records was optional (but is required under HFS+), so we may need to create those.
	for (ImpCatalogItem *_Nonnull const item in _sourceItemsThatNeedThreadRecords) {
		NSData *_Nonnull const keyData = item.destinationKey;
		struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
//			ImpPrintf(@"Item %p “%@” needs thread record: %@", item, [ImpBTreeNode describeHFSPlusCatalogKeyWithData:keyData], item.needsThreadRecord ? @"YES" : @"NO");
		if (item.needsThreadRecord) {
			NSMutableData *_Nonnull const threadKeyData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogKey)];
			struct HFSPlusCatalogKey *_Nonnull const threadKeyPtr = threadKeyData.mutableBytes;
			NSMutableData *_Nonnull const threadRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogThread)];
			struct HFSPlusCatalogThread *_Nonnull const threadRecPtr = threadRecData.mutableBytes;

			NSMutableData *_Nonnull const recData = item.destinationRecord;
			void *_Nonnull const recPtr = recData.mutableBytes;
			int16_t const *_Nonnull const recTypePtr = recPtr;
			struct HFSPlusCatalogFile *_Nonnull const filePtr = recPtr;
			struct HFSPlusCatalogFolder *_Nonnull const folderPtr = recPtr;

			//In a thread record, the key holds the item's *own* ID (despite being called “parentID”) and an empty name, while the thread record holds the item's *parent*'s ID and the item's own name.
			switch (L(*recTypePtr)) {
				case kHFSPlusFileRecord:
					threadKeyPtr->parentID = filePtr->fileID;
					S(threadRecPtr->recordType, kHFSPlusFileThreadRecord);
					S(filePtr->flags, L(filePtr->flags) | kHFSThreadExistsMask);
					break;
				case kHFSPlusFolderRecord:
					//Technically we shouldn't get here, either, as thread records were required for folders under HFS.
					threadKeyPtr->parentID = folderPtr->folderID;
					S(threadRecPtr->recordType, kHFSPlusFolderThreadRecord);
					S(folderPtr->flags, L(folderPtr->flags) | kHFSThreadExistsMask);
					break;
				default:
					__builtin_unreachable();
			}
			threadRecPtr->parentID = keyPtr->parentID;
			memcpy(&threadRecPtr->nodeName, &keyPtr->nodeName, sizeof(threadRecPtr->nodeName));
			//DiskWarrior complains about “oversized thread records” if the thread payload contains empty space. Plus, shrinking these down frees up space in the node for more records.
			u_int32_t const threadRecSize = sizeof(threadRecPtr->recordType) + sizeof(threadRecPtr->reserved) + sizeof(threadRecPtr->parentID) + sizeof(threadRecPtr->nodeName.length) + sizeof(UniChar) * L(threadRecPtr->nodeName.length);
			[threadRecData setLength:threadRecSize];

			//A thread key has a CNID and an empty node name (so, length 0). keyLength doesn't include itself.
			u_int16_t const threadKeySize = sizeof(threadKeyPtr->keyLength) + sizeof(threadKeyPtr->parentID) + sizeof(threadKeyPtr->nodeName.length);
			u_int16_t const threadKeyLength = threadKeySize - sizeof(threadKeyPtr->keyLength);
			S(threadKeyPtr->keyLength, threadKeyLength);
			[threadKeyData setLength:threadKeySize];

			item.destinationThreadKey = threadKeyData;
			item.destinationThreadRecord = threadRecData;
			item.needsThreadRecord = false;
		}
	}
}

- (void) buildMockTree {
	if (! _treeIsBuilt) {
		/*We can't just convert leaf records straight across in the same order, for three reasons:
		 *- For files, we probably need to add a thread record (optional in HFS, mandatory in HFS+).
		 *- File thread records may be at a very different position in the leaf row from the corresponding file record, because the file thread record's key has the file ID as its “parent ID”, whereas the file record's key has the actual parent (directory) of the file. These are two different CNIDs and cannot be assumed to be anywhere near each other in the number sequence.
		 *- The order of names (and therefore items) may change between HFS's MacRoman-ish 8-bit encoding and HFS+'s Unicode flavor. This not only changes the leaf row, it can also ripple up into the index.
		 *
		 *We need to grab the keys, the source file or folder records, and the source thread records, and generate a list of items. Each item has a converted file or folder record with corresponding key, and a converted or generated thread record and corresponding key. From these items, we can extract both records and put those key-value pairs into a sorted array, and then use that array to populate the converted leaf row.
		 *
		 *The list of items is built up by calls to the addKey:____Record: methods. By this point, all of those should have already happened.
		 */

		//Now we have all the items.
		if (self.version == ImpBTreeVersionHFSCatalog) {
			[self fillInHFSThreadRecords];
		} else if (self.version == ImpBTreeVersionHFSPlusCatalog) {
			[self fillInHFSPlusThreadRecords];
		}

		//Now all of our items have both a file or folder record and a thread record. Each of these is filed under a different key in the catalog file, due to their different purposes. (File and folder records are stored under a key containing their parent item's CNID; thread records are stored under a key containing the item's own CNID, for the purpose of finding the parent ID stored in the thread record.) So turn our list of n items into n * 2 key-value pairs, half of them being file or folder records and half being thread records. These will be the contents of the leaf row.
		_allKeyValuePairs = [NSMutableArray arrayWithCapacity:_allSourceItems.count];
		for (ImpCatalogItem *_Nonnull const item in _allSourceItems) {
//			ImpPrintf(@"Item from list of source items:");
//			if (item.sourceThreadKey != nil) ImpPrintf(@"\tSource thread key %@", [ImpBTreeNode describeHFSCatalogKeyWithData:item.sourceThreadKey]);
//			if (item.sourceThreadRecord != nil) ImpPrintf(@"\tSource thread record %@", [ImpBTreeNode describeHFSCatalogThreadRecordWithData:item.sourceThreadRecord]);
//			if (item.destinationKey != nil) ImpPrintf(@"\tDestination key %@", [ImpBTreeNode describeHFSPlusCatalogKeyWithData:item.destinationKey]);
//			if (item.destinationThreadKey != nil) ImpPrintf(@"\tDestination thread key %@", [ImpBTreeNode describeHFSPlusCatalogKeyWithData:item.destinationThreadKey]);
//			if (item.destinationThreadRecord != nil) ImpPrintf(@"\tDestination thread record %@", [ImpBTreeNode describeHFSPlusCatalogThreadRecordWithData:item.destinationThreadRecord]);

			[_allKeyValuePairs addObject:[[ImpCatalogKeyValuePair alloc] initWithKey:item.destinationKey value:item.destinationRecord]];
			[_allKeyValuePairs addObject:[[ImpCatalogKeyValuePair alloc] initWithKey:item.destinationThreadKey value:item.destinationThreadRecord]];
		}
		[_allKeyValuePairs sortUsingSelector:@selector(caseInsensitiveCompare:)];

		/*The algorithm for building the index is built around a loop that processes an entire row and produces a new row above the previous one.
		 *The initial row is the leaf row; each row produced above it is an index row.
		 *The first key from each node on the lower row is appended to the upper row, adding new nodes on the upper row as needed.
		 *Each round of the loop produces a significantly shorter row. (I haven't done the math but my intuitive sense is that it's an exponential curve following the approximate average number of keys per index node.) Every row will contain the first key in the leaf row, fulfilling that requirement.
		 *The loop ends when the upper row has been fully populated in one node. That node is the root node.
		 */
		u_int32_t const nodeBodySize = _nodeSize - (sizeof(struct BTNodeDescriptor) + sizeof(BTreeNodeOffset));

		//First, fill out the bottom row with mock leaf nodes. Each “mock node” is an array of NSDatas representing catalog keys; we separately track the total size of the pointer records (each of which is a key + a u_int32_t), so that when adding another key would exceed the capacity of a real node (nodeBodySize), we tear off that node and start the next one.
		NSMutableArray <ImpMockNode *> *_Nonnull const bottomRow = [NSMutableArray arrayWithCapacity:_allSourceItems.count];
		ImpMockNode *_Nullable thisMockNode = nil;

		//1 for the header node
		++_numLiveNodes;

		for (ImpCatalogKeyValuePair *_Nonnull const kvp in _allKeyValuePairs) {
			if (thisMockNode == nil) {
				thisMockNode = [[ImpMockNode alloc] initWithCapacity:nodeBodySize];
				thisMockNode.nodeHeight = 1;
				[bottomRow addObject:thisMockNode];
				++_numLiveNodes;
			}

			if (! [thisMockNode appendKey:kvp.key payload:kvp.value]) {
				thisMockNode = [[ImpMockNode alloc] initWithCapacity:nodeBodySize];
				thisMockNode.nodeHeight = 1;
				[bottomRow addObject:thisMockNode];
				++_numLiveNodes;

				NSAssert([thisMockNode appendKey:kvp.key payload:kvp.value], @"Encountered catalog entry too big to fit in a catalog node: Key is %lu bytes, payload is %lu bytes, but maximal node capacity is %u bytes", kvp.key.length, kvp.value.length, nodeBodySize);
			}
		}

		_mockRows = [NSMutableArray arrayWithCapacity:self.treeDepthHint];
		_allMockIndexNodes = [NSMutableArray arrayWithCapacity:_allSourceItems.count];
		[_mockRows addObject:bottomRow];

		while (_mockRows.firstObject.count > 1) {
			NSMutableArray <ImpMockIndexNode *> *_Nonnull upperRow = [NSMutableArray arrayWithCapacity:_allKeyValuePairs.count];
			ImpMockIndexNode *_Nullable indexNodeInProgress = nil;

			NSArray <ImpMockNode *> *_Nonnull const lowerRow = _mockRows.firstObject;
			for (ImpMockNode *_Nonnull const node in lowerRow) {
				if (indexNodeInProgress == nil) {
					indexNodeInProgress = [[ImpMockIndexNode alloc] initWithCapacity:nodeBodySize];
					indexNodeInProgress.nodeHeight = (u_int8_t)(_mockRows.count + 1);
					[upperRow addObject:indexNodeInProgress];
					++_numLiveNodes;
				}

				NSData *_Nonnull const keyData = node.firstKey;
				if (! [indexNodeInProgress appendKey:keyData fromNode:node]) {
					indexNodeInProgress = [[ImpMockIndexNode alloc] initWithCapacity:nodeBodySize];
					indexNodeInProgress.nodeHeight = (u_int8_t)(_mockRows.count + 1);
					[upperRow addObject:indexNodeInProgress];
					++_numLiveNodes;

					NSAssert([indexNodeInProgress appendKey:keyData fromNode:node], @"Encountered catalog entry too big to fit in a catalog index node: Key is %lu bytes, payload is %lu bytes, but maximal node capacity is %u bytes (%u already used)", keyData.length, sizeof(u_int32_t), nodeBodySize, indexNodeInProgress.totalSizeOfAllRecords);
				}
			}

			[_allMockIndexNodes addObjectsFromArray:upperRow];
			[_mockRows insertObject:upperRow atIndex:0];

			if (_largestCNIDYet < UINT32_MAX) {
				self.nextCatalogNodeID = _largestCNIDYet + 1;
				self.hasReusedCatalogNodeIDs = false;
			} else {
				self.nextCatalogNodeID = _firstUnusedCNID;
				self.hasReusedCatalogNodeIDs = true;
			}
		}

		_treeIsBuilt = true;
	}
}
- (void) invalidateMockTree {
	_treeIsBuilt = false;
}

- (NSUInteger) totalNodeCount {
	[self buildMockTree];

	return _numLiveNodes;
}

///Populate a real tree with the records added so far. Note that this method does not work incrementally, so it should only be used on a real tree. Create the tree with a number of nodes equal to or greater than totalNodeCount.
- (void) populateTree:(ImpMutableBTreeFile *_Nonnull const)destTree {
	[self buildMockTree];

	NSArray <NSArray <ImpMockNode *> *> *_Nonnull const mockRows = _mockRows;
	NSArray <ImpMockNode *> *_Nullable const topRow = mockRows.firstObject;
	NSArray <ImpMockNode *> *_Nullable const bottomRow = mockRows.lastObject;
	NSAssert(topRow != nil, @"No top row? The converted tree is empty!");
	NSAssert(topRow.count == 1, @"Somehow the top row ended up containing more than one node; it should only contain the root node, but contains %@", topRow);

	//Start creating real nodes.
	NSMutableArray <ImpBTreeNode *> *_Nonnull const allRealIndexNodes = [NSMutableArray arrayWithCapacity:_allMockIndexNodes.count];
	for (ImpMockIndexNode *_Nonnull const mockIndexNode in _allMockIndexNodes) {
		ImpBTreeNode *_Nonnull const realIndexNode = [destTree allocateNewNodeOfKind:kBTIndexNode populate:^(void * _Nonnull bytes, NSUInteger length) {
			struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
			nodeDesc->height = mockIndexNode.nodeHeight;
		}];
		[allRealIndexNodes addObject:realIndexNode];
		mockIndexNode.nodeNumber = realIndexNode.nodeNumber;
	}
	for (ImpMockNode *_Nonnull const mockNode in bottomRow) {
		ImpBTreeNode *_Nonnull const realLeafNode = [destTree allocateNewNodeOfKind:kBTLeafNode populate:^(void * _Nonnull bytes, NSUInteger length) {
			struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
			nodeDesc->height = 1;
		}];
		mockNode.nodeNumber = realLeafNode.nodeNumber;
	}

	//Convert the mock index nodes into real nodes.
	for (NSArray <ImpMockNode *> *_Nonnull const row in mockRows) {
		ImpBTreeNode *_Nullable lastRealNode = nil;
		for (ImpMockNode *_Nonnull const mockNode in row) {
			u_int32_t const nodeNumber = mockNode.nodeNumber;
			NSAssert(nodeNumber > 0, @"Can't copy a node with no node number. That would overwrite the header node, and that's bad!");
			ImpBTreeNode *_Nonnull const realNode = [destTree nodeAtIndex:nodeNumber];
			[mockNode writeIntoNode:realNode];
			[lastRealNode connectNextNode:realNode];
			lastRealNode = realNode;
		}
	}

	ImpMockNode *_Nonnull const mockRootNode = topRow.firstObject;
	u_int32_t const numLiveNodes = _numLiveNodes;
	NSArray <ImpCatalogKeyValuePair *> *_Nonnull keyValuePairs = _allKeyValuePairs;

	[destTree.headerNode reviseHeaderRecord:^(struct BTHeaderRec *_Nonnull const headerRecPtr) {
		S(headerRecPtr->rootNode, mockRootNode.nodeNumber);
		S(headerRecPtr->treeDepth, (u_int16_t)mockRows.count);
		S(headerRecPtr->firstLeafNode, bottomRow.firstObject.nodeNumber);
		S(headerRecPtr->lastLeafNode, bottomRow.lastObject.nodeNumber);
		S(headerRecPtr->leafRecords, (u_int32_t)keyValuePairs.count);
		u_int32_t const numPotentialNodes = (u_int32_t)destTree.numberOfPotentialNodes;
		u_int32_t const numFreeNodes = numPotentialNodes - numLiveNodes;
		S(headerRecPtr->totalNodes, numPotentialNodes);
		S(headerRecPtr->freeNodes, numFreeNodes);
	}];
}

#pragma mark Creation of original files

- (HFSCatalogNodeID) _HFSPlus_createFileInParent:(HFSCatalogNodeID)parentID
	name:(NSString *_Nonnull const)nodeName
	type:(OSType const)fileType
	creator:(OSType const)creator
	finderFlags:(UInt16)finderFlags
{
	//TEMP: Stolen from -buildMockTree, where it belongs. The whole CNID-assignment mechanism needs to be reworked; it's currently very ad-hoc.
	if (_largestCNIDYet < UINT32_MAX) {
		self.nextCatalogNodeID = _largestCNIDYet + 1;
		self.hasReusedCatalogNodeIDs = false;
	} else {
		self.nextCatalogNodeID = _firstUnusedCNID;
		self.hasReusedCatalogNodeIDs = true;
	}

	//TODO: Really should make this failable in case all possible CNIDs are in use.
	HFSCatalogNodeID const cnid = self.nextCatalogNodeID;
	ImpTextEncodingConverter *_Nonnull const tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	struct HFSUniStr255 nodeName255;
	[tec convertString:nodeName toHFSUniStr255:&nodeName255];

	{
		NSMutableData *_Nonnull const fileKeyData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogKey)];
		struct HFSPlusCatalogKey *_Nonnull const fileKeyPtr = fileKeyData.mutableBytes;
		S(fileKeyPtr->parentID, parentID);
		memcpy(&fileKeyPtr->nodeName, &nodeName255, sizeof(nodeName255));
		u_int16_t const keyLength = sizeof(fileKeyPtr->parentID) + sizeof(fileKeyPtr->nodeName.length) + sizeof(UniChar) * L(fileKeyPtr->nodeName.length);
		S(fileKeyPtr->keyLength, keyLength);
		fileKeyData.length = keyLength + sizeof(fileKeyPtr->keyLength);

		NSMutableData *_Nonnull const fileRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogFile)];
		struct HFSPlusCatalogFile *_Nonnull const fileRecPtr = fileRecData.mutableBytes;
		S(fileRecPtr->recordType, kHFSPlusFileRecord);
		S(fileRecPtr->flags, kHFSFileLockedMask | kHFSThreadExistsMask);
		S(fileRecPtr->fileID, cnid);
		NSDate *_Nonnull const now = [NSDate date];
		static NSTimeInterval hfsEpochTISRD = -3061152000.0; //1904-01-01T00:00:00Z timeIntervalSinceReferenceDate
		u_int32_t const nowSince1984 = (u_int32_t)(now.timeIntervalSinceReferenceDate - hfsEpochTISRD);
		S(fileRecPtr->createDate, nowSince1984);
		S(fileRecPtr->contentModDate, nowSince1984);
		S(fileRecPtr->backupDate, nowSince1984);
		//These two are not set by classic Mac OS, so ordinarily we would leave these fields alone. However, this is an original file being created by impluse in the present day, so making it distinguishable from files copied in from the past is desirable.
		S(fileRecPtr->attributeModDate, nowSince1984);
		S(fileRecPtr->accessDate, nowSince1984);

		struct HFSPlusBSDInfo bsdInfo;
		S(bsdInfo.ownerID, getuid());
		S(bsdInfo.groupID, getgid());
		bsdInfo.adminFlags = bsdInfo.ownerFlags = 0;
		S(bsdInfo.fileMode, 0444);
		bsdInfo.special.linkCount = 0;
		memcpy(&fileRecPtr->bsdInfo, &bsdInfo, sizeof(bsdInfo));

		struct FndrFileInfo userInfo;
		S(userInfo.fdType, fileType);
		S(userInfo.fdCreator, creator);
		userInfo.fdLocation.h = userInfo.fdLocation.v = CFSwapInt16HostToBig(16);
		S(userInfo.fdFlags, finderFlags);
		userInfo.opaque = 0;
		memcpy(&fileRecPtr->userInfo, &userInfo, sizeof(userInfo));

		struct FndrExtendedFileInfo extInfo;
		extInfo.document_id = 0;
		extInfo.date_added = nowSince1984;
		extInfo.extended_flags = kExtendedFlagsAreInvalid;
		extInfo.reserved2 = 0;
		extInfo.write_gen_counter = 0;
		memcpy(&fileRecPtr->finderInfo, &extInfo, sizeof(extInfo));

		S(fileRecPtr->textEncoding, kTextEncodingMacRoman);
		fileRecPtr->reserved1 = fileRecPtr->reserved2 = 0;

		S(fileRecPtr->dataFork.clumpSize, 4096);

		[self addKey:fileKeyData fileRecord:fileRecData];
	}

	{
		NSMutableData *_Nonnull const fileThreadKeyData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogKey)];
		struct HFSPlusCatalogKey *_Nonnull const fileThreadKeyPtr = fileThreadKeyData.mutableBytes;
		S(fileThreadKeyPtr->parentID, cnid);
		//Thread keys have an empty node name.
		u_int16_t const keyLength = sizeof(fileThreadKeyPtr->parentID) + sizeof(fileThreadKeyPtr->nodeName.length) + sizeof(UniChar) * L(fileThreadKeyPtr->nodeName.length);
		S(fileThreadKeyPtr->keyLength, keyLength);
		fileThreadKeyData.length = keyLength + sizeof(fileThreadKeyPtr->keyLength);

		NSMutableData *_Nonnull const fileThreadRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogThread)];
		struct HFSPlusCatalogThread *_Nonnull const fileThreadRecPtr = fileThreadRecData.mutableBytes;
		S(fileThreadRecPtr->recordType, kHFSPlusFileThreadRecord);
		S(fileThreadRecPtr->parentID, parentID);
		memcpy(&fileThreadRecPtr->nodeName, &nodeName255, sizeof(nodeName255));
		fileThreadRecPtr->reserved = 0;
		u_int32_t const threadRecSize = sizeof(fileThreadRecPtr->recordType) + sizeof(fileThreadRecPtr->reserved) + sizeof(fileThreadRecPtr->parentID) + sizeof(fileThreadRecPtr->nodeName.length) + sizeof(UniChar) * L(fileThreadRecPtr->nodeName.length);
		[fileThreadRecData setLength:threadRecSize];

		[self addKey:fileThreadKeyData threadRecord:fileThreadRecData];
	}

	return cnid;
}
- (HFSCatalogNodeID) createFileInParent:(HFSCatalogNodeID)parentID
	name:(NSString *_Nonnull const)nodeName
	type:(OSType const)fileType
	creator:(OSType const)creator
	finderFlags:(UInt16)finderFlags
{
	if (self.version == ImpBTreeVersionHFSPlusCatalog) {
		return [self _HFSPlus_createFileInParent:parentID
			name:nodeName
			type:fileType
			creator:creator
			finderFlags:finderFlags];
	} else {
		__builtin_unreachable();
		return 0;
	}
}

@end

#pragma mark -
#pragma mark Epilogue: Implementation of the helper classes

@implementation ImpCatalogItemIdentifier

+ (ImpTextEncodingConverter *_Nonnull const) reusableTextEncodingConverter {
	static ImpTextEncodingConverter *_Nullable _tec = nil;
	if (_tec == nil) {
		_tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	}
	return _tec;
}

- (instancetype) initWithParentCNID:(HFSCatalogNodeID const)parentID ownCNID:(HFSCatalogNodeID const)ownID nodeName:(NSString *_Nonnull const)nodeName {
	if ((self = [super init])) {
		_parentID = parentID;
		_ownID = ownID;
		_nodeName = [nodeName copy];
		_typeEmoji = @"📇";
	}
	return self;
}
+ (instancetype) identifierWithParentCNID:(HFSCatalogNodeID const)parentID ownCNID:(HFSCatalogNodeID const)ownID nodeName:(NSString *_Nonnull const)nodeName {
	return [[self alloc] initWithParentCNID:parentID ownCNID:ownID nodeName:nodeName];
}

#pragma mark Creating identifiers from HFS catalog entries

+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData fileRecordData:(NSData *_Nonnull const)fileRecData {
	struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSCatalogFile const *_Nonnull const fileRecPtr = fileRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(keyPtr->parentID) ownCNID:L(fileRecPtr->fileID) nodeName:[[self reusableTextEncodingConverter] stringForPascalString:keyPtr->nodeName fromHFSCatalogKey:keyPtr]];
	identifier.typeEmoji = @"📄";
	return identifier;
}
+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData folderRecordData:(NSData *_Nonnull const)folderRecData {
	struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSCatalogFolder const *_Nonnull const folderRecPtr = folderRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(keyPtr->parentID) ownCNID:L(folderRecPtr->folderID) nodeName:[[self reusableTextEncodingConverter] stringForPascalString:keyPtr->nodeName fromHFSCatalogKey:keyPtr]];
	identifier.typeEmoji = @"📁";
	return identifier;
}
+ (instancetype) identifierWithHFSCatalogKeyData:(NSData *_Nonnull const)keyData threadRecordData:(NSData *_Nonnull const)threadRecData {
	struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSCatalogThread const *_Nonnull const threadRecPtr = threadRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(threadRecPtr->parentID) ownCNID:L(keyPtr->parentID) nodeName:[[self reusableTextEncodingConverter] stringForPascalString:threadRecPtr->nodeName]];
	identifier.typeEmoji = (L(threadRecPtr->recordType) == kHFSFileThreadRecord) ? @"📄" : @"📁";
	return identifier;
}

#pragma mark Creating identifiers from HFS Plus catalog entries

+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData fileRecordData:(NSData *_Nonnull const)fileRecData {
	struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSPlusCatalogFile const *_Nonnull const fileRecPtr = fileRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(keyPtr->parentID) ownCNID:L(fileRecPtr->fileID) nodeName:[[self reusableTextEncodingConverter] stringFromHFSUniStr255:&keyPtr->nodeName]];
	identifier.typeEmoji = @"📄";
	return identifier;
}
+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData folderRecordData:(NSData *_Nonnull const)folderRecData {
	struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSPlusCatalogFolder const *_Nonnull const folderRecPtr = folderRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(keyPtr->parentID) ownCNID:L(folderRecPtr->folderID) nodeName:[[self reusableTextEncodingConverter] stringFromHFSUniStr255:&keyPtr->nodeName]];
	identifier.typeEmoji = @"📁";
	return identifier;
}
+ (instancetype) identifierWithHFSPlusCatalogKeyData:(NSData *_Nonnull const)keyData threadRecordData:(NSData *_Nonnull const)threadRecData {
	struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
	struct HFSPlusCatalogThread const *_Nonnull const threadRecPtr = threadRecData.bytes;
	ImpCatalogItemIdentifier *_Nonnull const identifier = [self identifierWithParentCNID:L(threadRecPtr->parentID) ownCNID:L(keyPtr->parentID) nodeName:[[self reusableTextEncodingConverter] stringFromHFSUniStr255:&threadRecPtr->nodeName]];
	identifier.typeEmoji = (L(threadRecPtr->recordType) == kHFSPlusFileThreadRecord) ? @"📄" : @"📁";
	return identifier;
}

#pragma mark Instance methods

- (id _Nonnull)copyWithZone:(NSZone *_Nullable)zone {
	return self;
}

- (NSUInteger) hash {
#if __LP64__
	NSUInteger const parentID = self.parentID;
	NSUInteger const ownID = self.ownID;
	return parentID << 32 | ownID;
#else
	return self.ownID;
#endif
}

- (BOOL) isEqual:(id _Nonnull)other {
	ImpCatalogItemIdentifier *_Nonnull const otherIdent = other;
	//TODO: Check this comment's veracity
	//Note: In this case we really want exact comparison, not the case-insensitive sorting comparison used for inserting newly-created items into a catalog.
	return self.ownID == otherIdent.ownID && self.parentID == otherIdent.parentID && [self.nodeName isEqualToString:otherIdent.nodeName];
}

- (NSString *_Nonnull) description {
	return [NSString stringWithFormat:@"<%@ %p for 📁 #%u → %@ #%u “%@”>", self.class, self, self.parentID, self.typeEmoji, self.ownID, self.nodeName];
}

@end

@implementation ImpCatalogItem

- (instancetype _Nonnull) initWithIdentifier:(ImpCatalogItemIdentifier *_Nonnull const)identifier {
	if ((self = [super init])) {
		_identifier = identifier;
		_cnid = _identifier.ownID;
		_needsThreadRecord = true;
	}
	return self;
}

- (NSUInteger)hash {
	return self.cnid;
}
- (BOOL)isEqual:(id _Nonnull)other {
	@try {
		ImpCatalogItem *_Nonnull const fellowCatalogItemHopefully = other;
		return [self.identifier isEqual:fellowCatalogItemHopefully.identifier];
	} @catch (NSException *_Nonnull const exception) {
		return false;
	}
}

- (NSComparisonResult) caseInsensitiveCompare:(id)other {
	ImpCatalogItem *_Nonnull const otherItem = other;
	return (NSComparisonResult)ImpBTreeCompareHFSPlusCatalogKeys(self.destinationKey.bytes, otherItem.destinationKey.bytes);
}

- (NSString *_Nonnull) description {
	NSMutableString *_Nonnull const description = [NSMutableString stringWithFormat:@"<%@ %p %CTR", self.class, self, (unichar)(self.needsThreadRecord ? 'N' : 'H')];
	NSData *_Nonnull const srcKeyData       = self.sourceKey;
	NSData *_Nonnull const srcThreadKeyData = self.sourceThreadKey;
	NSData *_Nonnull const srcThreadRecData = self.sourceThreadRecord;
	NSData *_Nonnull const dstKeyData       = self.destinationKey;
	NSData *_Nonnull const dstThreadKeyData = self.destinationThreadKey;
	NSData *_Nonnull const dstThreadRecData = self.destinationThreadRecord;
	if (srcKeyData || srcThreadKeyData || srcThreadRecData || dstKeyData       || dstThreadKeyData || dstThreadRecData) {
		if (srcKeyData) [description appendFormat:@"\nSK  %@", [ImpBTreeNode describeHFSCatalogKeyWithData:srcKeyData]];
		if (srcThreadKeyData) [description appendFormat:@"\nSTK %@", [ImpBTreeNode describeHFSCatalogKeyWithData:srcThreadKeyData]];
		if (srcThreadRecData) [description appendFormat:@"\nSTP %@", [ImpBTreeNode describeHFSCatalogThreadRecordWithData:srcThreadRecData]];
		if (dstKeyData) [description appendFormat:@"\nDK  %@", [ImpBTreeNode describeHFSPlusCatalogKeyWithData:dstKeyData]];
		if (dstThreadKeyData) [description appendFormat:@"\nDTK %@", [ImpBTreeNode describeHFSPlusCatalogKeyWithData:dstThreadKeyData]];
		if (dstThreadRecData) [description appendFormat:@"\nDTP %@", [ImpBTreeNode describeHFSPlusCatalogThreadRecordWithData:dstThreadRecData]];
		[description appendString:@"\n"];
	}
	[description appendString:@">"];
	return description;
}

@end

@implementation ImpCatalogKeyValuePair

- (instancetype _Nonnull)initWithKey:(NSData *_Nonnull const)keyData value:(NSData *_Nonnull const)valueData {
	ImpBTreeVersion const version = ImpGetCatalogKeyVersion(keyData);
	if (version == ImpBTreeVersionHFSCatalog) {
		NSParameterAssert(keyData.length >= kHFSCatalogKeyMinimumLength);
		NSParameterAssert(keyData.length <= kHFSCatalogKeyMaximumLength);
	} else if (version == ImpBTreeVersionHFSPlusCatalog) {
		NSParameterAssert(keyData.length >= kHFSPlusCatalogKeyMinimumLength);
		NSParameterAssert(keyData.length <= kHFSPlusCatalogKeyMaximumLength);
	}

	if ((self = [super init])) {
		_key = keyData;
		_value = valueData;
	}
	return self;
}

- (NSString *_Nonnull) description {
	NSString *_Nonnull valueDescription = @"(empty)";
	if (self.value.length > sizeof(u_int16_t)) {
		u_int16_t const *_Nonnull const recordTypePtr = self.value.bytes;
		switch (L(*recordTypePtr)) {
			case kHFSFileRecord:
			case kHFSPlusFileRecord:
				valueDescription = @"file";
				break;

			case kHFSFolderRecord:
			case kHFSPlusFolderRecord:
				valueDescription = @"folder";
				break;

			case kHFSFileThreadRecord:
			case kHFSPlusFileThreadRecord:
				valueDescription = @"file thread";
				break;

			case kHFSFolderThreadRecord:
			case kHFSPlusFolderThreadRecord:
				valueDescription = @"folder thread";
				break;

			default:
				valueDescription = [NSString stringWithFormat:@"(unknown: 0x%04x)", L(*recordTypePtr)];
				break;
		}
	}
	return [NSString stringWithFormat:@"<%@ %p with key %@ and value type '%@'>",
		self.class, self,
		[ImpBTreeNode describeHFSPlusCatalogKeyWithData:self.key],
		valueDescription
	];
}

- (NSComparisonResult) caseInsensitiveCompare:(id)other {
	ImpCatalogKeyValuePair *_Nonnull const otherPair = other;
	ImpBTreeVersion const thisVersion = ImpGetCatalogKeyVersion(self.key);
	ImpBTreeVersion const otherVersion = ImpGetCatalogKeyVersion(otherPair.key);
	if (thisVersion == ImpBTreeVersionHFSCatalog && otherVersion == ImpBTreeVersionHFSPlusCatalog) {
		return NSOrderedAscending;
	} else if (thisVersion == ImpBTreeVersionHFSPlusCatalog && otherVersion == ImpBTreeVersionHFSCatalog) {
		return NSOrderedDescending;
	} else if (thisVersion == ImpBTreeVersionHFSPlusCatalog) {
		return (NSComparisonResult)ImpBTreeCompareHFSPlusCatalogKeys(self.key.bytes, otherPair.key.bytes);
	} else if (thisVersion == ImpBTreeVersionHFSCatalog) {
		return (NSComparisonResult)ImpBTreeCompareHFSCatalogKeys(self.key.bytes, otherPair.key.bytes);
	} else {
		return NSOrderedSame;
	}
}

@end

@implementation ImpMockNode
{
	NSMutableArray <NSData *> *_Nonnull _allKeys;
	NSMutableArray <ImpCatalogKeyValuePair *> *_Nonnull _allPairs;
	u_int32_t _capacity;
}

- (instancetype) initWithCapacity:(u_int32_t const)maxNumBytes {
	if ((self = [super init])) {
		_capacity = maxNumBytes;
		_allKeys = [NSMutableArray arrayWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
		_allPairs = [NSMutableArray arrayWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
	}
	return self;
}

- (NSString *_Nonnull) description {
	return [NSString stringWithFormat:@"<%@ %p with records: %@>", self.class, self, _allPairs];
}

- (NSData *_Nullable) firstKey {
	return _allKeys.firstObject;
}

- (bool) canAppendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData {
	return (_capacity - _totalSizeOfAllRecords) >= (keyData.length + payloadData.length + sizeof(BTreeNodeOffset));
}

- (bool) appendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData {
	if ([self canAppendKey:keyData payload:payloadData]) {
		[_allKeys addObject:keyData];
		ImpCatalogKeyValuePair *_Nonnull const kvp = [[ImpCatalogKeyValuePair alloc] initWithKey:keyData value:payloadData];
		[_allPairs addObject:kvp];
		_totalSizeOfAllRecords += (keyData.length + payloadData.length + sizeof(BTreeNodeOffset));
		return true;
	}
	return false;
}

- (void) writeIntoNode:(ImpBTreeNode *const)realNode {
	for (ImpCatalogKeyValuePair *_Nonnull const kvp in _allPairs) {
		bool const appended = [realNode appendRecordWithKey:kvp.key payload:kvp.value];
		NSAssert(appended, @"Could not append record to real node %@; it may be out of space (%u bytes remaining; key is %lu bytes and payload is %lu bytes)", realNode, realNode.numberOfBytesAvailable, kvp.key.length, kvp.value.length);
	}
}

- (NSArray <NSData *> *_Nonnull const) allKeys {
	return _allKeys;
}

@end

@implementation ImpMockIndexNode
{
	NSMutableDictionary <NSData *, ImpMockNode *> *_pointerRecords;
}

- (instancetype)initWithCapacity:(const u_int32_t)maxNumBytes {
	if ((self = [super initWithCapacity:maxNumBytes])) {
		_pointerRecords = [NSMutableDictionary dictionaryWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
	}
	return self;
}

///Append a key to the node's list of pointer records, linked to the provided node.
- (bool) appendKey:(NSData *_Nonnull const)keyData fromNode:(ImpMockNode *_Nonnull const)descendantNode {
	NSMutableData *_Nonnull const blankPayloadData = [NSMutableData dataWithLength:sizeof(u_int32_t)];
	//We don't actually write descendantNode.nodeNumber into blankPayloadData because it hasn't been set yet, so we would just be overwriting the zero with a zero. Our overridden writeIntoNode: will get the real node number at the appropriate time. We're just using this blank NSData to represent the appropriate amount of space.

	if ([self appendKey:keyData payload:blankPayloadData]) {
		_pointerRecords[keyData] = descendantNode;
		return true;
	}
	return false;
}

///Add records to a real index node to match the contents of this mock node.
- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode {
	NSParameterAssert([realNode isKindOfClass:[ImpBTreeIndexNode class]]);

	ImpBTreeIndexNode *_Nonnull const realIndexNode = (ImpBTreeIndexNode *_Nonnull const)realNode;
	for (NSData *_Nonnull const key in self.allKeys) {
		ImpMockNode *_Nonnull const obj = _pointerRecords[key];

		NSMutableData *_Nonnull const payloadData = [NSMutableData dataWithLength:sizeof(u_int32_t)];
		u_int32_t *_Nonnull const pointerRecordPtr = payloadData.mutableBytes;
		S(*pointerRecordPtr, obj.nodeNumber);

//		NSString *_Nonnull const filename = [ImpBTreeNode nodeNameFromHFSPlusCatalogKey:key];
//		ImpPrintf(@"Node #%u: Wrote index record for file “%@”: %u -(swap)-> %u", realIndexNode.nodeNumber, filename, obj.nodeNumber, *pointerRecordPtr);

		[realIndexNode appendRecordWithKey:key payload:payloadData];
	}
}

@end
