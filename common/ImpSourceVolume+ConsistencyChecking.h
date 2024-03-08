//
//  ImpSourceVolume+ConsistencyChecking.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-12-23.
//

#import "ImpSourceVolume.h"

@class ImpBTreeFile;

@interface ImpSourceVolume (ConsistencyChecking)

///Perform some consistency checks on the catalog file and return either true and nil, or false and an NSError describing any and all failures.
- (bool) checkCatalogFile:(out NSError *_Nullable *_Nonnull const)outError;

@end
