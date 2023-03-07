//
//  ImpCatalogBuilder.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-06.
//

#import <Foundation/Foundation.h>

#import "ImpBTreeTypes.h"

@class ImpMutableBTreeFile;

@class ImpCatalogItem;

/*!A catalog builder is a helper object that encapsulates the construction of an HFS+ catalog tree. It's meant to be fed with HFS+ catalog keys and records such as those created by converting HFS catalog keys and records.
 *One benefit of encapsulating it this way is that the object can track state such as the number of records added to the catalog and the number of nodes needed to hold them.
 *This enables clients of the catalog builder—namely, converter objects—to use the catalog builder to determine the precise number of nodes the real tree will need to hold, create a real tree of that size, and then have the catalog builder populate it.
 */

@interface ImpCatalogBuilder : NSObject

///Create a catalog builder that can create a catalog tree of the specified version. Currently, the only supported version is ImpBTreeVersionHFSPlusCatalog.
- (instancetype _Nullable) initWithBTreeVersion:(ImpBTreeVersion const)version
	bytesPerNode:(u_int16_t const)nodeSize
	expectedNumberOfItems:(NSUInteger const)numItems;

///An idea of what tree depth to expect. You could set this to the tree depth of a source tree being converted. Set it to 0 if you're not sure.
@property u_int16_t treeDepthHint;

///Add a file record to the new tree's leaf row. The layout of the key and payload must be consistent with the version of tree being built (i.e., they must be HFS+ if the version is HFS+) and with each other (an HFS+ file record for an HFS+ key).
- (void) addKey:(NSMutableData *_Nonnull const)keyData fileRecord:(NSMutableData *_Nonnull const)payloadData;

///Add a folder record to the new tree's leaf row. The layout of the key and payload must be consistent with the version of tree being built (i.e., they must be HFS+ if the version is HFS+) and with each other (an HFS+ folder record for an HFS+ key).
- (void) addKey:(NSMutableData *_Nonnull const)keyData folderRecord:(NSMutableData *_Nonnull const)payloadData;

///Add a thread record to the new tree's leaf row. The layout of the key and payload must be consistent with the version of tree being built (i.e., they must be HFS+ if the version is HFS+) and with each other (an HFS+ thread record for an HFS+ key).
- (void) addKey:(NSMutableData *_Nonnull const)keyData threadRecord:(NSMutableData *_Nonnull const)payloadData;

///The number of nodes required to hold the entire tree so far, including the header node, any map nodes, and any index nodes.
- (NSUInteger) totalNodeCount;

@property(readonly) HFSCatalogNodeID nextCatalogNodeID;
@property(readonly) bool hasReusedCatalogNodeIDs;

///Populate a real tree with the records added so far. Note that this method does not work incrementally, so it should only be used on a real tree. Create the tree with a number of nodes equal to or greater than totalNodeCount.
- (void) populateTree:(ImpMutableBTreeFile *_Nonnull const)tree;

@end
