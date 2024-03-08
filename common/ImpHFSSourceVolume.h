//
//  ImpHFSSourceVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpSourceVolume.h"

#import <hfs/hfs_format.h>

@interface ImpHFSSourceVolume : ImpSourceVolume

- (void) peekAtHFSVolumeHeader:(void (^_Nonnull const)(struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr NS_NOESCAPE))block;

@end
