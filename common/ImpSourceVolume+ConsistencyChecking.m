//
//  ImpSourceVolume+ConsistencyChecking.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-12-23.
//

#import "ImpSourceVolume+ConsistencyChecking.h"

#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"

@implementation ImpSourceVolume (ConsistencyChecking)

- (bool) checkBTreeFile:(ImpBTreeFile *_Nonnull const)bTreeFile failureDescriptions:(NSMutableArray <NSString *> *_Nonnull const)failureDescriptions {
	NSMutableArray *_Nonnull const thisCheckFailures = [NSMutableArray array];
	if (bTreeFile.numberOfPotentialNodes <= 0) {
		[thisCheckFailures addObject:@"B*-tree does not have space for even a single node."];
		goto end;
	}

	//Check header node.
	{
		ImpBTreeNode *_Nonnull const probablyHeaderNode = [bTreeFile nodeAtIndex:0];
		if (probablyHeaderNode.nodeType != kBTHeaderNode) {
			[thisCheckFailures addObject:@"First node is not a header node."];
			goto end;
		}
		ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull)probablyHeaderNode;
		if (! [bTreeFile isValidIndex:headerNode.rootNodeIndex]) {
			[thisCheckFailures addObject:@"Header node does not have a valid link to the root node."];
			goto end;
		}
	}

	//Check root nodes.
	{
		ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull)[bTreeFile nodeAtIndex:0];

		u_int32_t nodeIndex = headerNode.rootNodeIndex;
		u_int32_t posWithinRow = 0;
		ImpBTreeNode *_Nonnull const rootNode = headerNode.rootNode;
		ImpBTreeNode *_Nullable rootLevelNode = rootNode;
		while (rootLevelNode != nil) {
			if (! [rootLevelNode validateLinkToPreviousNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Root node at index #%u (index #%u within row) has an invalid backward link.", nodeIndex, posWithinRow]];
			}
			if (! [rootLevelNode validateLinkToNextNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Root node at index #%u (index #%u within row) has an invalid forward link.", nodeIndex, posWithinRow]];
				goto end;
			} else {
				nodeIndex = rootLevelNode.forwardLink;
				rootLevelNode = rootLevelNode.nextNode;
				++posWithinRow;
			}
		}
	}

	//Check header node.
	{
		ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull)[bTreeFile nodeAtIndex:0];

		if (! [bTreeFile isValidIndex:headerNode.firstLeafNodeIndex]) {
			[thisCheckFailures addObject:[NSString stringWithFormat:@"Invalid first leaf node index: %u (max index in tree is %lu", headerNode.firstLeafNodeIndex, bTreeFile.numberOfPotentialNodes]];
			goto end;
		}
		if (! [bTreeFile isValidIndex:headerNode.lastLeafNodeIndex]) {
			[thisCheckFailures addObject:[NSString stringWithFormat:@"Invalid last leaf node index: %u (max index in tree is %lu", headerNode.lastLeafNodeIndex, bTreeFile.numberOfPotentialNodes]];
			goto end;
		}
	}

	//Check leaf nodes forward.
	{
		ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull)[bTreeFile nodeAtIndex:0];

		u_int32_t nodeIndex = headerNode.firstLeafNodeIndex;
		u_int32_t posWithinRow = 0;
		ImpBTreeNode *_Nullable leafNode = [bTreeFile nodeAtIndex:nodeIndex];
		while (leafNode != nil) {
			if (! [leafNode validateLinkToPreviousNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Forward search: Leaf node at index #%u (index #%u within row) has an invalid backward link (%u of %lu).", nodeIndex, posWithinRow, leafNode.backwardLink, bTreeFile.numberOfPotentialNodes]];
			}
			if (! [leafNode validateLinkToNextNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Forward search: Leaf node at index #%u (index #%u within row) has an invalid forward link (%u of %lu).", nodeIndex, posWithinRow, leafNode.forwardLink, bTreeFile.numberOfPotentialNodes]];
				break;
			} else {
				nodeIndex = leafNode.forwardLink;
				leafNode = leafNode.nextNode;
				++posWithinRow;
			}
		}
	}

	//Check leaf nodes backward.
	{
		ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull)[bTreeFile nodeAtIndex:0];

		u_int32_t nodeIndex = headerNode.lastLeafNodeIndex;
		int32_t posWithinRow = -1;
		ImpBTreeNode *_Nullable leafNode = [bTreeFile nodeAtIndex:nodeIndex];
		while (leafNode != nil) {
			if (! [leafNode validateLinkToNextNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Backward search: Leaf node at index #%u (index #%d within row) has an invalid forward link (%u of %lu).", nodeIndex, posWithinRow, leafNode.forwardLink, bTreeFile.numberOfPotentialNodes]];
			}
			if (! [leafNode validateLinkToPreviousNode]) {
				[thisCheckFailures addObject:[NSString stringWithFormat:@"Backward search: Leaf node at index #%u (index #%d within row) has an invalid backward link (%u of %lu).", nodeIndex, posWithinRow, leafNode.backwardLink, bTreeFile.numberOfPotentialNodes]];
				break;
			} else {
				nodeIndex = leafNode.backwardLink;
				leafNode = leafNode.previousNode;
				--posWithinRow;
			}
		}
	}

end:
	[failureDescriptions addObjectsFromArray:thisCheckFailures];
	return thisCheckFailures.count == 0;
}
- (bool) checkCatalogFile:(out NSError *_Nullable *_Nonnull const)outError {
	NSMutableArray <NSString *> *_Nonnull const failureDescriptions = [NSMutableArray array];

	ImpBTreeFile *_Nonnull const catFile = self.catalogBTree;
	bool const passed = [self checkBTreeFile:catFile failureDescriptions:failureDescriptions];
	if (! passed) {
		NSError *_Nonnull const error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Catalog file contains errors:\n- %@", [failureDescriptions componentsJoinedByString:@"\n- "]] }];
		*outError = error;
	}
	return passed;
}

@end
