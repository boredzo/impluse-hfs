//
//  ImpHFSVolume+ConsistencyChecking.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-12-23.
//

#import "ImpHFSVolume.h"

@class ImpBTreeFile;

@interface ImpHFSVolume (ConsistencyChecking)

///Perform some consistency checks on the catalog file and return either true and nil, or false and an NSError describing any and all failures.
- (bool) checkCatalogFile:(out NSError *_Nullable *_Nonnull const)outError;

@end
