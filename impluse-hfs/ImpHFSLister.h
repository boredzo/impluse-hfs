//
//  ImpHFSLister.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import <Foundation/Foundation.h>

@interface ImpHFSLister : NSObject

///Which encoding to interpret HFS volume, folder, and file names as. Defaults to MacRoman.
@property TextEncoding hfsTextEncoding;

///Read an HFS volume from this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable sourceDevice;

- (bool)performInventoryOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
