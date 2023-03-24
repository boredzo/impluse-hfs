//
//  ImpSizeUtilities.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-01-18.
//

#import "ImpSizeUtilities.h"

#import <Foundation/Foundation.h>
#import <hfs/hfs_format.h>

#import "ImpByteOrder.h"

u_int32_t ImpNumberOfBlocksInHFSExtentRecord(struct HFSExtentDescriptor const *_Nonnull const extRec) {
	u_int32_t total = 0;
	for (NSUInteger i = 0; i < kHFSExtentDensity; ++i) {
		u_int16_t const numBlocksThisExtent = L(extRec[i].blockCount);
		if (numBlocksThisExtent == 0) {
			break;
		} else {
			total += numBlocksThisExtent;
		}
	}
	return total;
}

u_int64_t ImpNumberOfBlocksInHFSPlusExtentRecord(struct HFSPlusExtentDescriptor const *_Nonnull const extRec) {
	u_int64_t total = 0;
	for (NSUInteger i = 0; i < kHFSPlusExtentDensity; ++i) {
		u_int32_t const numBlocksThisExtent = L(extRec[i].blockCount);
		if (numBlocksThisExtent == 0) {
			break;
		} else {
			total += numBlocksThisExtent;
		}
	}
	return total;
}

NSString *_Nonnull ImpDescribeHFSExtentRecord(struct HFSExtentDescriptor const *_Nonnull const extRec)
{
	NSMutableArray <NSString *> *_Nonnull const extentDescriptions = [NSMutableArray arrayWithCapacity:kHFSExtentDensity];
	for (NSUInteger i = 0; i < kHFSExtentDensity; ++i) {
		u_int16_t const numBlocks = L(extRec[i].blockCount);
		if (numBlocks == 0) {
			break;
		}

		u_int16_t const firstBlock = L(extRec[i].startBlock);
		u_int16_t const lastBlock = firstBlock + (numBlocks - 1);
		[extentDescriptions addObject:[NSString stringWithFormat:@"%u–%u", firstBlock, lastBlock]];
	}

	return extentDescriptions.count > 0 ? [extentDescriptions componentsJoinedByString:@", "] : @"(empty)";
}

NSString *_Nonnull ImpDescribeHFSPlusExtentRecord(struct HFSPlusExtentDescriptor const *_Nonnull const extRec)
{
	NSMutableArray <NSString *> *_Nonnull const extentDescriptions = [NSMutableArray arrayWithCapacity:kHFSPlusExtentDensity];
	for (NSUInteger i = 0; i < kHFSPlusExtentDensity; ++i) {
		u_int32_t const numBlocks = L(extRec[i].blockCount);
		if (numBlocks == 0) {
			break;
		}

		u_int32_t const firstBlock = L(extRec[i].startBlock);
		u_int32_t const lastBlock = firstBlock + (numBlocks - 1);
		[extentDescriptions addObject:[NSString stringWithFormat:@"%u–%u", firstBlock, lastBlock]];
	}

	return extentDescriptions.count > 0 ? [extentDescriptions componentsJoinedByString:@", "] : @"(empty)";
}
