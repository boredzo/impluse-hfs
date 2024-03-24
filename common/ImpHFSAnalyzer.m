//
//  ImpHFSAnalyzer.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import "ImpHFSAnalyzer.h"

#import "ImpSizeUtilities.h"
#import "ImpTextEncodingConverter.h"

#import "ImpSourceVolume.h"
#import "ImpSourceVolume+ConsistencyChecking.h"
#import "ImpHFSSourceVolume.h"
#import "ImpHFSPlusSourceVolume.h"
#import "ImpDestinationVolume.h"
#import "ImpVolumeProbe.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

@interface ImpHFSAnalyzer ()

- (bool) analyzeVolume:(ImpSourceVolume *_Nonnull const)srcVol error:(NSError *_Nullable *_Nonnull) outError;

@end
@implementation ImpHFSAnalyzer

- (bool)performAnalysisOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	__block bool analyzed = false;
	__block NSError *_Nullable volumeLoadError = nil;
	__block NSError *_Nullable analysisError = nil;

	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:readFD];
	probe.verbose = true;
	[probe findVolumes:^(const u_int64_t startOffsetInBytes, const u_int64_t lengthInBytes, Class  _Nullable const __unsafe_unretained volumeClass) {
		ImpSourceVolume *_Nonnull const srcVol = [[volumeClass alloc] initWithFileDescriptor:readFD startOffsetInBytes:startOffsetInBytes lengthInBytes:lengthInBytes textEncoding:self.hfsTextEncoding];
		analyzed = [self analyzeVolume:srcVol error:&analysisError] || analyzed;
	}];

	if (! analyzed) {
		if (outError != NULL) {
			*outError = volumeLoadError ?: analysisError;
		}
	}

	return analyzed;
}
- (bool) analyzeVolume:(ImpSourceVolume *_Nonnull const)srcVol error:(NSError *_Nullable *_Nonnull) outError {
	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];

	int const readFD = srcVol.fileDescriptor;
	if (! [srcVol readBootBlocksFromFileDescriptor:readFD error:outError]) {
		return false;
	}
	if (! [srcVol readVolumeHeaderFromFileDescriptor:readFD error:outError]) {
		return false;
	}

	ImpHFSSourceVolume *_Nullable const hfsVol = [srcVol isKindOfClass:[ImpHFSSourceVolume class]] ? (ImpHFSSourceVolume *)srcVol : nil;
	ImpHFSPlusSourceVolume *_Nullable const hfsPlusVol = [srcVol isKindOfClass:[ImpHFSPlusSourceVolume class]] ? (ImpHFSPlusSourceVolume *)srcVol : nil;

	[hfsPlusVol peekAtHFSPlusVolumeHeader:^(NS_NOESCAPE const struct HFSPlusVolumeHeader *const vhPtr) {
		ImpPrintf(@"Found HFS+ volume");

		NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
		fmtr.numberStyle = NSNumberFormatterDecimalStyle;
		fmtr.hasThousandSeparators = true;

		u_int64_t const catNumBytes = L(vhPtr->catalogFile.logicalSize);
		ImpPrintf(@"Catalog file logical length: 0x%llx bytes (%@)", catNumBytes, [bcf stringFromByteCount:catNumBytes]);
		struct HFSPlusExtentDescriptor const *_Nonnull const catExtDescs = vhPtr->catalogFile.extents;
		for (NSUInteger i = 0; i < kHFSPlusExtentDensity && catExtDescs[i].blockCount > 0; ++i) {
			ImpPrintf(@"Catalog extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
		}

		u_int64_t const eoNumBytes = L(vhPtr->extentsFile.logicalSize);
		ImpPrintf(@"Extents overflow file logical length: 0x%llx bytes (%@)", eoNumBytes, [bcf stringFromByteCount:eoNumBytes]);
		struct HFSPlusExtentDescriptor const *_Nonnull const eoExtDescs = vhPtr->extentsFile.extents;
		for (NSUInteger i = 0; i < kHFSPlusExtentDensity && eoExtDescs[i].blockCount > 0; ++i) {
			ImpPrintf(@"Extents overflow extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
		}
	}];
	[hfsVol peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		ImpPrintf(@"Found HFS volume with name: %@", [srcVol.textEncodingConverter stringForPascalString:mdbPtr->drVN]);

		NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
		fmtr.numberStyle = NSNumberFormatterDecimalStyle;
		fmtr.hasThousandSeparators = true;

		u_int32_t const catNumBytes = L(mdbPtr->drCTFlSize);
		ImpPrintf(@"Catalog file logical length: 0x%x bytes (%@)", catNumBytes, [bcf stringFromByteCount:catNumBytes]);

		struct HFSExtentDescriptor const *_Nonnull const catExtDescs = mdbPtr->drCTExtRec;
		ImpPrintf(@"Catalog extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
		ImpPrintf(@"Catalog extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[1].blockCount))]);
		ImpPrintf(@"Catalog extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[2].blockCount))]);

		u_int32_t const eoNumBytes = L(mdbPtr->drXTFlSize);
		ImpPrintf(@"Extents overflow file logical length: 0x%x bytes (%@)", eoNumBytes, [bcf stringFromByteCount:eoNumBytes]);

		struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = mdbPtr->drXTExtRec;
		ImpPrintf(@"Extents overflow extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
		ImpPrintf(@"Extents overflow extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[1].blockCount))]);
		ImpPrintf(@"Extents overflow extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[2].blockCount))]);
	}];

	if (! [srcVol readAllocationBitmapFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read allocation bitmap: %@", (*outError).localizedDescription);
		return false;
	}

	if (! [srcVol readExtentsOverflowFileFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read extents overflow file: %@", (*outError).localizedDescription);
		return false;
	}
	ImpBTreeFile *_Nonnull const extTree = srcVol.extentsOverflowBTree;
	ImpPrintf(@"Extents file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", extTree.numberOfLiveNodes, extTree.numberOfPotentialNodes, extTree.numberOfPotentialNodes > 0 ? (extTree.numberOfLiveNodes / (double)extTree.numberOfPotentialNodes) * 100.0 : 1.0);
	ImpPrintf(@"Extents file has a max depth of %u; its root node is at height %u while its first leaf is at height %u and its last leaf is at height %u (those three may all be the same node)", extTree.headerNode.treeDepth, extTree.headerNode.rootNode.nodeHeight, extTree.headerNode.firstLeafNode.nodeHeight, extTree.headerNode.lastLeafNode.nodeHeight);

	if (! [srcVol readCatalogFileFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read catalog file: %@", (*outError).localizedDescription);
		return false;
	}
	if ( ! [srcVol checkCatalogFile:outError]) {
		ImpPrintf(@"Faults detected in catalog file: %@", (*outError).localizedDescription);
		return false;
	}
	ImpBTreeFile *_Nonnull const catTree = srcVol.catalogBTree;
	ImpPrintf(@"Catalog file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", catTree.numberOfLiveNodes, catTree.numberOfPotentialNodes, catTree.numberOfPotentialNodes > 0 ? (catTree.numberOfLiveNodes / (double)catTree.numberOfPotentialNodes) * 100.0 : 1.0);
	ImpPrintf(@"Catalog file has a max depth of %u; its root node is at height %u while its first leaf is at height %u and its last leaf is at height %u (those three may all be the same node)", catTree.headerNode.treeDepth, catTree.headerNode.rootNode.nodeHeight, catTree.headerNode.firstLeafNode.nodeHeight, catTree.headerNode.lastLeafNode.nodeHeight);

	u_int32_t const blockSize = (u_int32_t)srcVol.numberOfBytesPerBlock;
	void (^_Nonnull const logFork)(char const *_Nonnull const indentString, char const *_Nonnull const forkName, HFSPlusForkData const *_Nonnull const forkPtr) = ^(char const *_Nonnull const indentString, char const *_Nonnull const forkName, HFSPlusForkData const *_Nonnull const forkPtr) {
		u_int64_t const numBlocksFromExtentRec = ImpNumberOfBlocksInHFSPlusExtentRecord(forkPtr->extents);
		u_int64_t const lsize = L(forkPtr->logicalSize);
		u_int64_t const psize = L(forkPtr->totalBlocks) * blockSize;
		u_int64_t const esize = numBlocksFromExtentRec * blockSize;
		ImpPrintf(@"%s%s: lsize %llu (mod blocksize = %llu), psize %u blocks (%llu bytes), extent sum %llu blocks (%llu bytes)",
			indentString, forkName,
			lsize, lsize % blockSize,
			L(forkPtr->totalBlocks), psize,
			numBlocksFromExtentRec, esize
		);
		if (lsize > psize) {
			ImpPrintf(@"%s🚨 %s: lsize is greater than psize. Likely causes: Endianness issue; stale/incorrect psize.", indentString, forkName);
		}
		if (psize != esize) {
			ImpPrintf(@"%s🚨 %s: psize (totalBlocks) does not match sum of extent blockCounts. Likely causes: Endianness issue; one or both are stale/incorrect.", indentString, forkName);
		}
		ImpPrintf(@"%s%s extents: %@", indentString, forkName, ImpDescribeHFSPlusExtentRecord(forkPtr->extents));
	};

	ImpPrintf(@"Volume's name is “%@”", srcVol.volumeName);
	ImpPrintf(@"“%@” contains %lu files and %lu folders", srcVol.volumeName, srcVol.numberOfFiles, srcVol.numberOfFolders);
	ImpPrintf(@"Allocation block size is %u (%x) bytes; volume has %lu blocks in use, %lu free, for a total of %lu total", srcVol.numberOfBytesPerBlock, srcVol.numberOfBytesPerBlock, srcVol.numberOfBlocksUsed, srcVol.numberOfBlocksFree, srcVol.numberOfBlocksTotal);

	[hfsPlusVol peekAtHFSPlusVolumeHeader:^(NS_NOESCAPE const struct HFSPlusVolumeHeader *const vhPtr) {
		ImpPrintf(@"Volume attributes: 0x%08x", L(vhPtr->attributes));
		ImpPrintf(@"Creation date: %u", L(vhPtr->createDate));
		ImpPrintf(@"Modification date: %u", L(vhPtr->modifyDate));
		ImpPrintf(@"Space remaining (from volume header): %u blocks (0x%llx bytes)", L(vhPtr->freeBlocks), L(vhPtr->freeBlocks) * (u_int64_t)hfsPlusVol.numberOfBytesPerBlock);
		u_int32_t const numBitsFreeInBitmap = [srcVol numberOfBlocksFreeAccordingToBitmap];
		ImpPrintf(@"Space remaining (from allocations bitmap): %u blocks (0x%llx bytes)", numBitsFreeInBitmap, numBitsFreeInBitmap * (u_int64_t)hfsPlusVol.numberOfBytesPerBlock);
		ImpPrintf(@"Clump size for data forks is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(vhPtr->dataClumpSize), L(vhPtr->dataClumpSize) / (double)kISOStandardBlockSize, L(vhPtr->dataClumpSize) / (double)hfsPlusVol.numberOfBytesPerBlock);
		ImpPrintf(@"Clump size for resource forks is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(vhPtr->dataClumpSize), L(vhPtr->dataClumpSize) / (double)kISOStandardBlockSize, L(vhPtr->dataClumpSize) / (double)hfsPlusVol.numberOfBytesPerBlock);
		logFork("", "Allocations file", &(vhPtr->allocationFile));
		logFork("", "Extents overflow file", &(vhPtr->extentsFile));
		logFork("", "Catalog file", &(vhPtr->catalogFile));
	}];
	[hfsVol peekAtHFSVolumeHeader:^(NS_NOESCAPE struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr) {
		ImpPrintf(@"Creation date: %u", L(mdbPtr->drCrDate));
		ImpPrintf(@"First allocation block: 0x%llx", (u_int64_t)(L(mdbPtr->drAlBlSt) * kISOStandardBlockSize));
		ImpPrintf(@"Space remaining: %u blocks (0x%llx bytes)", L(mdbPtr->drFreeBks), (u_int64_t)(L(mdbPtr->drFreeBks) * L(mdbPtr->drAlBlkSiz)));
		ImpPrintf(@"Clump size is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(mdbPtr->drClpSiz), L(mdbPtr->drClpSiz) / (double)kISOStandardBlockSize, L(mdbPtr->drClpSiz) / (double)L(mdbPtr->drAlBlkSiz));
	}];

	ImpPrintf(@"Volume size is %@; %@ in use, %@ free", [bcf stringFromByteCount:blockSize * srcVol.numberOfBlocksTotal], [bcf stringFromByteCount:blockSize * srcVol.numberOfBlocksUsed], [bcf stringFromByteCount:blockSize * srcVol.numberOfBlocksFree]);

	ImpBTreeFile *_Nonnull const catalog = srcVol.catalogBTree;
	ImpPrintf(@"Slurped catalog file: %@", catalog);
	fflush(stdout);

	ImpBTreeNode *_Nonnull const firstNode = [catalog nodeAtIndex:0];
	NSAssert(firstNode != nil, @"Empty catalog file! %@", catalog);
	NSAssert(firstNode.nodeType == kBTHeaderNode, @"First node in catalog must be a header node, but it was actually a %@", firstNode.nodeTypeName);

	ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull const)firstNode;
	u_int32_t const numLiveNodes = headerNode.numberOfTotalNodes - headerNode.numberOfFreeNodes;
	ImpPrintf(@"Header node portends %u total nodes, of which %u are free (= %u used)", headerNode.numberOfTotalNodes, headerNode.numberOfFreeNodes, numLiveNodes);

	ImpBTreeNode *_Nonnull const rootNode = headerNode.rootNode;
	ImpPrintf(@"Root node is %@", rootNode);

	__block NSUInteger numNodes = 0;
	__block NSUInteger lastEncounteredHeight = rootNode.nodeHeight;
	__block NSUInteger numNodesThisRow = 0;
	NSMutableArray <NSString *> *_Nonnull const nodeIndexStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];
	NSMutableArray <NSString *> *_Nonnull const indexNodePointerCountStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];
	__block NSUInteger numNodesPointedToByPointerRecordsThisRow = 0;
	NSMutableArray <NSString *> *_Nonnull const indexNodeContentsStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];

	NSString *_Nonnull (^_Nonnull const abbreviateFilename)(ConstStr31Param) = ^NSString *_Nonnull(ConstStr31Param nodeName) {
		NSString *_Nonnull const fullName = [srcVol.textEncodingConverter stringForPascalString:nodeName];
		if (fullName.length <= 3) {
			return fullName;
		}
		return [fullName stringByReplacingCharactersInRange:(NSRange){ 3, fullName.length - 3 } withString:@"…"];
	};

	NSString *_Nonnull (^_Nonnull const emojiForNodeType)(BTreeNodeKind kind) = ^NSString *_Nonnull(BTreeNodeKind kind) {
		switch (kind) {
			case kBTLeafNode:
				return @"🍁";
			case kBTIndexNode:
				return @"🗂";
			case kBTHeaderNode:
				return @"👤";
			case kBTMapNode:
				return @"🗺";
			default:
				return @"💣";
		}
	};

	NSMutableSet *_Nonnull const nodesPreviouslyEncountered = [NSMutableSet setWithCapacity:headerNode.numberOfTotalNodes];
	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if ([nodesPreviouslyEncountered containsObject:@(node.nodeNumber)]) {
			ImpPrintf(@"Walk encountered node AGAIN(???): %@", node);
			return true;
		}
		[nodesPreviouslyEncountered addObject:@(node.nodeNumber)];
		++numNodes;

		NSUInteger const thisHeight = node.nodeHeight;
		if (thisHeight != lastEncounteredHeight) {
			if (lastEncounteredHeight != NSUIntegerMax) {
				ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@", "]);
				if (indexNodePointerCountStrings.count > 0) {
					ImpPrintf(@"⬇️⬇️⬇️:\t\t(%@) = %lu", [indexNodePointerCountStrings componentsJoinedByString:@" + "], numNodesPointedToByPointerRecordsThisRow);
					ImpPrintf(@"⬇️⬇️⬇️:\t\t(\n\t%@\n\t)", [indexNodeContentsStrings componentsJoinedByString:@",\n\t"]);
				}
			}
			lastEncounteredHeight = thisHeight;
			numNodesThisRow = 0;
			[nodeIndexStrings removeAllObjects];
			[indexNodePointerCountStrings removeAllObjects];
			numNodesPointedToByPointerRecordsThisRow = 0;
			[indexNodeContentsStrings removeAllObjects];
		}

		++numNodesThisRow;

		NSString *_Nonnull const emoji = emojiForNodeType(node.nodeType);
		[nodeIndexStrings addObject:[NSString stringWithFormat:@"%@%u(%u)", emoji, (u_int32_t)node.nodeNumber, node.numberOfRecords]];
		if (node.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)node;
			[indexNodePointerCountStrings addObject:[NSString stringWithFormat:@"%u", indexNode.numberOfRecords]];
			numNodesPointedToByPointerRecordsThisRow += indexNode.numberOfRecords;

			NSMutableArray *_Nonnull const pointerRecordDescriptions = [NSMutableArray arrayWithCapacity:indexNode.numberOfRecords];
			[indexNode forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
				struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
				u_int32_t const *_Nonnull const nodeIndexPtr = payloadData.bytes;
				NSString *_Nonnull const desc = [NSString stringWithFormat:@"📦%u\"%@\"➡️%@%u", L(keyPtr->parentID), abbreviateFilename(keyPtr->nodeName), emojiForNodeType([catalog nodeAtIndex:L(*nodeIndexPtr)].nodeType), L(*nodeIndexPtr)];
				[pointerRecordDescriptions addObject:desc];
				return true;
			}];
			[indexNodeContentsStrings addObject:[NSString stringWithFormat:@"🗂%u [ %@ ]", indexNode.nodeNumber, [pointerRecordDescriptions componentsJoinedByString:@", "]]];
		}

		return true;
	}];
	if (lastEncounteredHeight != NSUIntegerMax) {
		ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@","]);
	}

	NSNumberFormatter *_Nonnull const nf = [NSNumberFormatter new];
	nf.hasThousandSeparators = true;

	__block NSUInteger numFiles = 0, numFolders = 0, numThreads = 0;
	NSCountedSet <NSNumber *> *_Nonnull catalogNodeIDsEncountered = [NSCountedSet setWithCapacity:srcVol.numberOfFiles + srcVol.numberOfFolders];

	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if (node.nodeType == kBTLeafNode) {
			//Each of these will only return HFS or HFS+ catalog entries, so call both. If it's an HFS volume, we'll get HFS entries; if it's HFS+, we'll get HFS+ entries.
			__block NSUInteger recordIdx = 0;
			[node forEachHFSCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
				ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterForHFSFile:fileRec fallback:srcVol.textEncodingConverter];
				struct ExtendedFileInfo const *_Nonnull const extFinderInfo = (struct ExtendedFileInfo const *)&(fileRec->finderInfo);
				UInt16 const extFinderFlags = L(extFinderInfo->extendedFinderFlags);
				bool const hasEmbeddedScriptCode = [ImpTextEncodingConverter hasTextEncodingInExtendedFinderFlags:extFinderFlags];
				TextEncoding const embeddedScriptCode = [ImpTextEncodingConverter textEncodingFromExtendedFinderFlags:extFinderFlags];
				ImpPrintf(@"- %u:%lu 📄 “%@”, ID #%u (0x%x), type %@ creator %@, script code %@", node.nodeNumber, recordIdx++, [tec stringByEscapingString:[tec stringForPascalString:catalogKeyPtr->nodeName fromHFSCatalogKey:catalogKeyPtr]], L(fileRec->fileID), L(fileRec->fileID),  NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdCreator)), hasEmbeddedScriptCode ? [NSString stringWithFormat:@"%u", embeddedScriptCode] : @"default");
				ImpPrintf(@"    Parent ID: #%u (0x%x)", L(catalogKeyPtr->parentID), L(catalogKeyPtr->parentID));

				NSMutableArray <NSString *> *_Nonnull const extentDescriptions = [NSMutableArray arrayWithCapacity:3];
				__block u_int64_t totalBlockCount = 0;
				__block u_int64_t totalPhysicalLength = 0;
				///" []" times three extents times three extent records.
				enum { numExtraCharacters = 3 * 3 * 3 };
				NSMutableString *_Nonnull blockCheckResults = [NSMutableString stringWithCapacity:ImpCeilingDivide(L(fileRec->dataPhysicalSize), blockSize) + numExtraCharacters];

				u_int64_t (^_Nonnull const checkExtentValidity)(const struct HFSExtentDescriptor *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining) = ^u_int64_t(const struct HFSExtentDescriptor *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining) {
					[extentDescriptions addObject:ImpDescribeHFSExtent(oneExtent)];

					u_int64_t const blockCount = ImpNumberOfBlocksInHFSExtent(oneExtent);
					u_int64_t const byteCount = blockCount * blockSize;
					totalBlockCount += blockCount;
					totalPhysicalLength += byteCount;

					[blockCheckResults appendString:@" ["];
					ImpIterateHFSExtent(oneExtent, ^(u_int32_t const blockNumber) {
						bool const isValidBlockNumber = [srcVol isBlockInBounds:blockNumber];
						bool const isAllocated = [srcVol isBlockAllocated:blockNumber];
						if (isValidBlockNumber && isAllocated) {
							[blockCheckResults appendString:@"✅"];
						} else if (isValidBlockNumber && ! isAllocated) {
							[blockCheckResults appendString:@"☠️"];
						} else if (isAllocated && ! isValidBlockNumber) {
							[blockCheckResults appendString:@"🚀"];
						} else {
							[blockCheckResults appendString:@"🌌"];
						}
					});
					[blockCheckResults appendString:@"]"];

					return byteCount;
				};

				char const *_Nonnull const indentString = "\t";

				char const *_Nonnull forkName = "DF";
				u_int64_t lsize = L(fileRec->dataLogicalSize);
				u_int64_t psize = L(fileRec->dataPhysicalSize);
				[hfsVol forEachExtentInFileWithID:L(fileRec->fileID)
					fork:ImpForkTypeData
					forkLogicalLength:lsize
					startingWithExtentsRecord:fileRec->dataExtents
					block:checkExtentValidity];
				ImpPrintf(@"%s%s: lsize %@ (mod blocksize = %llu), psize %@ bytes, extent sum %@ blocks (%@ bytes)",
					indentString, forkName,
					[nf stringFromNumber:@(lsize)], lsize % blockSize,
					[nf stringFromNumber:@(psize)],
					[nf stringFromNumber:@(totalBlockCount)], [nf stringFromNumber:@(totalPhysicalLength)]
				);
				if (lsize > psize) {
					ImpPrintf(@"%s🚨 %s: lsize is greater than psize. Likely causes: Endianness issue; stale/incorrect psize.", indentString, forkName);
				}
				if (psize != totalPhysicalLength) {
					ImpPrintf(@"%s🚨 %s: psize (totalBlocks) does not match sum of extent blockCounts. Likely causes: Endianness issue; one or both are stale/incorrect.", indentString, forkName);
				}
				ImpPrintf(@"%s%s blocks: %@", indentString, forkName, blockCheckResults);

				[extentDescriptions removeAllObjects];
				totalBlockCount = totalPhysicalLength = 0;
				blockCheckResults = [NSMutableString stringWithCapacity:ImpCeilingDivide(L(fileRec->rsrcPhysicalSize), blockSize) + numExtraCharacters];

				forkName = "RF";
				lsize = L(fileRec->rsrcLogicalSize);
				psize = L(fileRec->rsrcPhysicalSize);
				[hfsVol forEachExtentInFileWithID:L(fileRec->fileID)
					fork:ImpForkTypeResource
					forkLogicalLength:lsize
					startingWithExtentsRecord:fileRec->rsrcExtents
					block:checkExtentValidity];
				ImpPrintf(@"%s%s: lsize %@ (mod blocksize = %llu), psize %@ bytes, extent sum %@ blocks (%@ bytes)",
					indentString, forkName,
					[nf stringFromNumber:@(lsize)], lsize % blockSize,
					[nf stringFromNumber:@(psize)],
					[nf stringFromNumber:@(totalBlockCount)], [nf stringFromNumber:@(totalPhysicalLength)]
				);
				if (lsize > psize) {
					ImpPrintf(@"%s🚨 %s: lsize is greater than psize. Likely causes: Endianness issue; stale/incorrect psize.", indentString, forkName);
				}
				if (psize != totalPhysicalLength) {
					ImpPrintf(@"%s🚨 %s: psize (totalBlocks) does not match sum of extent blockCounts. Likely causes: Endianness issue; one or both are stale/incorrect.", indentString, forkName);
				}
				ImpPrintf(@"%s%s blocks: %@", indentString, forkName, blockCheckResults);

				++numFiles;
				[catalogNodeIDsEncountered addObject:@(L(fileRec->fileID))];
			} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
				ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterForHFSFolder:folderRec fallback:srcVol.textEncodingConverter];
				struct ExtendedFolderInfo const *_Nonnull const extFinderInfo = (struct ExtendedFolderInfo const *)&(folderRec->finderInfo);
				UInt16 const extFinderFlags = L(extFinderInfo->extendedFinderFlags);
				ImpPrintf(@"- %u:%lu 📁 “%@” with ID #%u, %u items, script code %@", node.nodeNumber, recordIdx++, [tec stringByEscapingString:[tec stringForPascalString:catalogKeyPtr->nodeName fromHFSCatalogKey:catalogKeyPtr]], L(folderRec->folderID), L(folderRec->valence), [ImpTextEncodingConverter hasTextEncodingInExtendedFinderFlags:extFinderFlags] ? [NSString stringWithFormat:@"%u", [ImpTextEncodingConverter textEncodingFromExtendedFinderFlags:extFinderFlags]] : @"default");
				ImpPrintf(@"    Script code: 0x%x", ((struct DXInfo const *_Nonnull const)extFinderInfo)->frScript);
				ImpPrintf(@"    Node flags: 0x%04x", L(folderRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(folderRec->userInfo.frFlags), L(extFinderInfo->extendedFinderFlags));
				ImpPrintf(@"    Creation date: %u", L(folderRec->createDate));
				++numFolders;
				[catalogNodeIDsEncountered addObject:@(L(folderRec->folderID))];
			} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
				u_int32_t const ownID = L(catalogKeyPtr->parentID);
				u_int32_t const parentID = L(threadRec->parentID);
				ImpPrintf(@"- %u:%lu %@🧵 puts item #%u, with name “%@”, in parent ID #%u", node.nodeNumber, recordIdx++, L(threadRec->recordType) == kHFSFileThreadRecord ? @"📄" : @"📁", ownID, [[srcVol.textEncodingConverter stringForPascalString:threadRec->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], parentID);
				++numThreads;
			}];
			NSString *_Nonnull (^_Nonnull const flagsString)(u_int16_t const itemFlags, u_int16_t const finderFlags, u_int16_t const extFinderFlags) = ^NSString *_Nonnull (u_int16_t const itemFlags, u_int16_t const finderFlags, u_int16_t const extFinderFlags) {
				//avbstclinmedz (order used by GetFileInfo(1))
				return [NSString stringWithFormat:@"%c%c%c%c%c%c%c%c%c%c%c%c%c",
					finderFlags & kIsAlias ? 'A' : 'a',
					finderFlags & kIsInvisible ? 'V' : 'v',
					finderFlags & kHasBundle ? 'B' : 'b',
					finderFlags & kNameLocked ? 'S' : 's',
					finderFlags & kIsStationery ? 'T' : 't',
					finderFlags & kHasCustomIcon ? 'C' : 'c',
					itemFlags & kHFSFileLockedMask  ? 'L' : 'l',
					finderFlags & kHasBeenInited ? 'I' : 'i',
					finderFlags & kHasNoINITs ? 'N' : 'n',
					finderFlags & kIsShared ? 'M' : 'm',
					'.', //extension hidden—not sure how to get this
					finderFlags & kIsOnDesk ? 'D' : 'd',
					extFinderFlags & kExtendedFlagObjectIsBusy ? 'Z' : 'z'
				];
			};
			[node forEachHFSPlusCatalogRecord_file:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogFile *const _Nonnull fileRec) {
				struct FndrExtendedFileInfo const *_Nonnull const extFinderInfo = (struct FndrExtendedFileInfo const *)&(fileRec->finderInfo);
				TextEncoding const enc = L(fileRec->textEncoding);
				ImpPrintf(@"- %u:%lu 📄 #%u/“%@”, ID #%u (0x%x), type %@ creator %@, flags %@, text encoding %u", node.nodeNumber, recordIdx++, L(catalogKeyPtr->parentID), [[srcVol.textEncodingConverter stringFromHFSUniStr255:&catalogKeyPtr->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], L(fileRec->fileID), L(fileRec->fileID),  NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdCreator)), flagsString(L(fileRec->flags), L(fileRec->userInfo.fdFlags), L(extFinderInfo->extended_flags)), enc);
				ImpPrintf(@"    Name encoding: 0x%x “%@”", enc, [ImpTextEncodingConverter nameOfTextEncoding:enc]);
				ImpPrintf(@"    Node flags: 0x%04x", L(fileRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(fileRec->userInfo.fdFlags), L(extFinderInfo->extended_flags));
				logFork("    ", "DF", &(fileRec->dataFork));
				logFork("    ", "RF", &(fileRec->resourceFork));
				++numFiles;
				[catalogNodeIDsEncountered addObject:@(L(fileRec->fileID))];
			} folder:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogFolder *const _Nonnull folderRec) {
				struct FndrExtendedFileInfo const *_Nonnull const extFinderInfo = (struct FndrExtendedFileInfo const *)&(folderRec->finderInfo);
				TextEncoding const enc = L(folderRec->textEncoding);
				ImpPrintf(@"- %u:%lu 📁 #%u/“%@” with ID #%u, %u items, text encoding %u", node.nodeNumber, recordIdx++, L(catalogKeyPtr->parentID), [[srcVol.textEncodingConverter stringFromHFSUniStr255:&catalogKeyPtr->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], L(folderRec->folderID), L(folderRec->valence), enc);
				ImpPrintf(@"    Name encoding: 0x%x “%@”", enc, [ImpTextEncodingConverter nameOfTextEncoding:enc]);
				ImpPrintf(@"    Node flags: 0x%04x", L(folderRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(folderRec->userInfo.frFlags), L(extFinderInfo->extended_flags));
				ImpPrintf(@"    Creation date: %u", L(folderRec->createDate));
				++numFolders;
				[catalogNodeIDsEncountered addObject:@(L(folderRec->folderID))];
			} thread:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogThread *const _Nonnull threadRec) {
				u_int32_t const ownID = L(catalogKeyPtr->parentID);
				u_int32_t const parentID = L(threadRec->parentID);
				ImpPrintf(@"- %u:%lu %@🧵 puts item #%u, with name “%@”, in parent ID #%u", node.nodeNumber, recordIdx++, L(threadRec->recordType) == kHFSPlusFileThreadRecord ? @"📄" : @"📁", ownID, [[srcVol.textEncodingConverter stringFromHFSUniStr255:&threadRec->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], parentID);
				++numThreads;
			}];
		}
		return true;
	}];
	ImpPrintf(@"Encountered %lu nodes", numNodes);

	NSMutableArray <NSNumber *> *_Nonnull const cnidsInOrder = [[catalogNodeIDsEncountered allObjects] mutableCopy];
	[cnidsInOrder sortUsingSelector:@selector(compare:)];
	ImpPrintf(@"Next catalog node ID is %u", srcVol.nextCatalogNodeID);
	ImpPrintf(@"Highest CNID in catalog is %u", cnidsInOrder.lastObject.unsignedIntValue);

	//The actual intent here is “numFolders != srcVol.numberOfFolders”, but the former needs 1 subtracted (or the latter needs 1 added) and that risks under/overflow.
	//So instead we check that numFolders > srcVol.numberOfFolders (i.e., we can subtract the latter from the former) and that the former minus the latter is 1.
	bool const numItemsDiffered = numFiles != srcVol.numberOfFiles || (
		(numFolders <= srcVol.numberOfFolders)
		|| ((numFolders - srcVol.numberOfFolders) != 1)
	);
	ImpPrintf(@"Encountered %lu files, %lu folders (including root directory), %lu threads", numFiles, numFolders, numThreads);
	ImpPrintf(@"%@Volume header says it has %lu files, %lu folders (excluding root directory)", numItemsDiffered ? @"🚨 " : @"", (unsigned long)srcVol.numberOfFiles, (unsigned long)srcVol.numberOfFolders);

	return true;
}

@end
