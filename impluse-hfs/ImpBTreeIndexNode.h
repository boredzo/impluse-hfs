//
//  ImpBTreeIndexNode.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#import "ImpBTreeNode.h"

@interface ImpBTreeIndexNode : ImpBTreeNode

- (NSArray <ImpBTreeNode *> *_Nonnull const) children;

@end
