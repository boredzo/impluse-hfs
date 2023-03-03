//
//  ImpExtentSeries.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-29.
//

#import <Foundation/Foundation.h>

#import <hfs/hfs_format.h>

///An extent series is a ordered, mutable collection object that holds a series of HFSPlusExtentDescriptors.
///(It isn't called an extent array because it doesn't hold NSObjects.)
///An extent series is a generalization of an extent record, which holds a finite number of extent descriptors. HFS extent records hold up to three extents; HFS+ extent records hold up to eight. An extent series is unbounded, and can be used to centralize a file's extents before redistribution to the new catalog and (if needed) extents overflow files.
///Appending to an extent series also performs consolidation: If a newly-appended extent is adjacent to the existing last extent, the last extent is extended to include it instead of appending a new extent. This is one of the ways that large files that needed to be in the HFS extents overflow file solely because of HFS's data range limits (HFS extents use 16-bit values) may be eligible for withdrawal from the extents overflow file, because they may no longer need so many extents.
@interface ImpExtentSeries : NSObject

@property(readonly) NSUInteger numberOfExtents;

///Note: May lengthen the last extent instead of appending a new extent if the new extent would be adjacent to the last extent. In that case, numberOfExtents will not change.
- (void) appendHFSExtent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtDesc;
///Extend the series by up to one full record. Note: May consolidate the last existing extent + some of the new extents if such consolidation is possible.
///numberOfExtents will increase by an amount between zero and three (kHFSExtentDensity). Only new extents added will be counted for increase. Empty extents (length zero) and any subsequent extents will not be added.
///All of this means that it is possible to append an HFS extent record of entirely consecutive adjacent extents that are all consecutive to the last existing extent, and consequently have the last extent in the series grow but numberOfExtents remain unchanged.
- (void) appendHFSExtentRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec;

///The extent record to put in a file's catalog entry, or the special files' entries in the volume header.
- (NSData *_Nonnull const) firstHFSPlusExtentRecord;

///Additional extent records, if needed, to be inserted into the extents overflow file. Each item in the array is one HFSPlusExtentRecord, suitable for adding as a record in the extents overflow file. If numberOfExtents <= kHFSPlusExtentDensity (which is 8), then this will be an empty array.
- (NSArray <NSData *> *_Nonnull const) overflowHFSPlusExtentRecords;

///Copy one extent record's worth of extents directly into an extent record buffer you already have.
- (void) getHFSPlusExtentRecordAtIndex:(NSUInteger const)extentRecordIndex buffer:(struct HFSPlusExtentDescriptor *_Nonnull const)outPtr;

///Call this block for every extent in the series, in order. The series will not contain any empty extents, so the block will never be called with an empty extent.
- (void) forEachExtent:(void (^_Nonnull const)(struct HFSPlusExtentDescriptor const *_Nonnull const))block;

@end
