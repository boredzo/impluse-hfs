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

- (NSArray <ImpBTreeNode *> *_Nonnull const) children {
	NSMutableArray *_Nonnull const children = [NSMutableArray arrayWithCapacity:self.numberOfRecords];

	ImpBTreeFile *_Nonnull const tree = self.tree;
	[self forEachRecord:^(NSData *const  _Nonnull data) {
		void const *_Nonnull const ptr = data.bytes;
		u_int32_t const *_Nonnull const nodeIndexPtr = (ptr + data.length - sizeof(u_int32_t));
		[children addObject:[tree nodeAtIndex:L(*nodeIndexPtr)]];
	}];

	return children;
}

@end
