//
//  ImpBTreeFile.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-27.
//

#import "ImpBTreeFile.h"

#import <hfs/hfs_format.h>
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

@implementation ImpBTreeFile
{
	NSData *_Nonnull _bTreeData;
	struct BTreeNode const *_Nonnull _nodes;
	NSUInteger _numNodes;
	NSMutableArray *_Nullable _lastEnumeratedObjects;
}

- (instancetype _Nullable)initWithData:(NSData *_Nonnull const)bTreeFileContents {
	if ((self = [super init])) {
		_bTreeData = [bTreeFileContents copy];
		[_bTreeData writeToURL:[[NSURL fileURLWithPath:@"/tmp" isDirectory:true] URLByAppendingPathComponent:@"hfs-catalog.dat" isDirectory:false] options:0 error:NULL];

		_nodes = _bTreeData.bytes;
		_numNodes = _bTreeData.length / sizeof(struct BTreeNode);
	}
	return self;
}

- (NSString *_Nonnull) description {
	return [NSString stringWithFormat:@"<%@ %p with estimated %lu nodes>", self.class, self, self.count];
}

- (NSUInteger)count {
	return _numNodes;
}

- (ImpBTreeHeaderNode *_Nullable const) headerNode {
	ImpBTreeNode *_Nonnull const node = [self nodeAtIndex:0];
	if (node.nodeType == kBTHeaderNode) {
		return (ImpBTreeHeaderNode *_Nonnull const)node;
	}
	return nil;
}

- (ImpBTreeNode *_Nonnull const) nodeAtIndex:(u_int32_t const)idx {
	//TODO: Create all of these once, probably up front, and keep them in an array. Turn this into objectAtIndex: and the fast enumeration into fast enumeration of that array.
	NSRange const nodeByteRange = { sizeof(struct BTreeNode) * idx, sizeof(struct BTreeNode) };
	NSData *_Nonnull const nodeData = [_bTreeData subdataWithRange:nodeByteRange];

	ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:nodeData];
	node.nodeNumber = idx;
	return node;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *_Nonnull)state
	objects:(__unsafe_unretained id  _Nullable [_Nonnull])outObjects
	count:(NSUInteger)maxNumObjects
{
	NSRange const lastReturnedRange = {
		state->extra[0],
		state->extra[1],
	};
	NSRange nextReturnedRange = {
		lastReturnedRange.location + lastReturnedRange.length,
		maxNumObjects,
	};
	if (nextReturnedRange.location >= self.count) {
		return 0;
	}
	if (NSMaxRange(nextReturnedRange) >= self.count) {
		nextReturnedRange.length = self.count - nextReturnedRange.location;
	}

	if (_lastEnumeratedObjects == nil) {
		_lastEnumeratedObjects = [NSMutableArray arrayWithCapacity:nextReturnedRange.length];
	} else {
		[_lastEnumeratedObjects removeAllObjects];
	}
	for (NSUInteger	i = 0; i < nextReturnedRange.length; ++i) {
		NSRange const nodeByteRange = { sizeof(struct BTreeNode) * ( nextReturnedRange.location + i), sizeof(struct BTreeNode) };
		NSData *_Nonnull const data = [_bTreeData subdataWithRange:nodeByteRange];
		ImpBTreeNode *_Nonnull const node = [ImpBTreeNode nodeWithTree:self data:data];
		node.nodeNumber = (u_int32_t)(nextReturnedRange.location + i);
		[_lastEnumeratedObjects addObject:node];
		outObjects[i] = node;
	}
	state->extra[0] = nextReturnedRange.location;
	state->extra[1] = nextReturnedRange.length;
	state->mutationsPtr = &_numNodes;
	state->itemsPtr = outObjects;
	return nextReturnedRange.length;
}

- (NSUInteger) _walkNodeAndItsSiblingsAndThenItsChildren:(ImpBTreeNode *_Nonnull const)startNode block:(void (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	NSUInteger numNodesVisited = 0;

	for (ImpBTreeNode *_Nullable node = startNode; node != nil; node = node.nextNode) {
		block(node);
		++numNodesVisited;
	}
	for (ImpBTreeNode *_Nullable node = startNode; node != nil; node = node.nextNode) {
		if (node.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)node;
			for (ImpBTreeNode *_Nonnull const child in indexNode.children) {
				numNodesVisited = [self _walkNodeAndItsSiblingsAndThenItsChildren:child block:block];
			}
		}
	}
	return numNodesVisited;
}
- (NSUInteger) walkBreadthFirst:(void (^_Nonnull const)(ImpBTreeNode *_Nonnull const node))block {
	ImpBTreeHeaderNode *_Nullable const headerNode = self.headerNode;
	if (headerNode == nil) {
		//No header node. Welp!
		return 0;
	}

	ImpBTreeNode *_Nullable const rootNode = headerNode.rootNode;
	if (rootNode == nil) {
		//No root node. Welp!
		return 0;
	}

	return [self _walkNodeAndItsSiblingsAndThenItsChildren:rootNode block:block];
}

@end
