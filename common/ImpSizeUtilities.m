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

#pragma mark Extent utilities

u_int32_t ImpFirstBlockInHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec) {
	return L(extRec->startBlock);
}
u_int32_t ImpLastBlockInHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec) {
	u_int32_t const blockCount = ImpNumberOfBlocksInHFSExtent(extRec);
	if (blockCount > 0) {
		return ImpFirstBlockInHFSExtent(extRec) + (blockCount - 1);
	} else {
		//There's kind of no valid answer here.
		return ImpFirstBlockInHFSExtent(extRec);
	}
}

u_int32_t ImpNumberOfBlocksInHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec) {
	return L(extRec->blockCount);
}

u_int32_t ImpFirstBlockInHFSPlusExtent(struct HFSPlusExtentDescriptor const *_Nonnull const extRec) {
	return L(extRec->startBlock);
}
u_int32_t ImpLastBlockInHFSPlusExtent(struct HFSPlusExtentDescriptor const *_Nonnull const extRec) {
	u_int32_t const blockCount = ImpNumberOfBlocksInHFSPlusExtent(extRec);
	if (blockCount > 0) {
		return ImpFirstBlockInHFSPlusExtent(extRec) + (blockCount - 1);
	} else {
		//There's kind of no valid answer here.
		return ImpFirstBlockInHFSPlusExtent(extRec);
	}
}

u_int32_t ImpNumberOfBlocksInHFSPlusExtent(struct HFSPlusExtentDescriptor const *_Nonnull const extRec) {
	return L(extRec->blockCount);
}

#pragma mark Descriptions

NSString *_Nonnull ImpDescribeHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec) {
	u_int32_t const startBlock = ImpFirstBlockInHFSExtent(extRec);
	u_int32_t const blockCount = ImpNumberOfBlocksInHFSExtent(extRec);
	if (blockCount > 0) {
		return [NSString stringWithFormat:@"extent starting at block #%u, for %u blocks, ending at block %u", startBlock, blockCount, ImpLastBlockInHFSExtent(extRec)];
	} else if (startBlock > 0) {
		return [NSString stringWithFormat:@"empty extent starting at block #%u", startBlock];
	} else {
		return @"empty extent";
	}
}

///Returns a string concisely describing one extent.
NSString *_Nonnull ImpDescribeHFSPlusExtent(struct HFSPlusExtentDescriptor const *_Nonnull const extRec) {
	u_int32_t const startBlock = ImpFirstBlockInHFSPlusExtent(extRec);
	u_int32_t const blockCount = ImpNumberOfBlocksInHFSPlusExtent(extRec);
	if (blockCount > 0) {
		return [NSString stringWithFormat:@"extent starting at block #%u, for %u blocks, ending at block %u", startBlock, blockCount, ImpLastBlockInHFSPlusExtent(extRec)];
	} else if (startBlock > 0) {
		return [NSString stringWithFormat:@"empty extent starting at block #%u", startBlock];
	} else {
		return @"empty extent";
	}
}

void ImpIterateHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec, void (^_Nonnull const block)(u_int32_t const blockNumber)) {
	u_int32_t const startBlock = ImpFirstBlockInHFSExtent(extRec);
	u_int32_t const blockCount = ImpNumberOfBlocksInHFSExtent(extRec);
	for (u_int32_t i = 0; i < blockCount; ++i) {
		block(startBlock + i);
	}
}

#pragma mark Extent record utilities

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
