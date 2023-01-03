//
//  ImpHFSAnalyzer.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import "ImpHFSAnalyzer.h"

#import "ImpSizeUtilities.h"
#import "ImpTextEncodingConverter.h"

#import "ImpHFSVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

@implementation ImpHFSAnalyzer

- (bool)performAnalysisOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD textEncoding:self.hfsTextEncoding];
	if (! [srcVol readBootBlocksFromFileDescriptor:readFD error:outError]) {
		ImpPrintf(@"Failed to read boot blocks (most likely means the volume is too small to hold an HFS volume): %@", (*outError).localizedDescription);
		return false;
	}
	if (! [srcVol readVolumeHeaderFromFileDescriptor:readFD error:outError]) {
		ImpPrintf(@"Failed to read volume header (most likely means the volume is too small to hold an HFS volume): %@", (*outError).localizedDescription);
		return false;
	}
	[srcVol peekAtVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		ImpPrintf(@"Found HFS volume with name: %@", [srcVol.textEncodingConverter stringForPascalString:mdbPtr->drVN]);

		NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
		fmtr.numberStyle = NSNumberFormatterDecimalStyle;
		fmtr.hasThousandSeparators = true;

		struct HFSExtentDescriptor const *_Nonnull const catExtDescs = mdbPtr->drCTExtRec;
		ImpPrintf(@"Catalog extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
		ImpPrintf(@"Catalog extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[1].blockCount))]);
		ImpPrintf(@"Catalog extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[2].blockCount))]);

		struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = mdbPtr->drXTExtRec;
		ImpPrintf(@"Extents overflow extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
		ImpPrintf(@"Extents overflow extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[1].blockCount))]);
		ImpPrintf(@"Extents overflow extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[2].blockCount))]);
	}];
	if (! [srcVol readAllocationBitmapFromFileDescriptor:readFD error:outError]) {
		ImpPrintf(@"Failed to read allocation bitmap: %@", (*outError).localizedDescription);
		return false;
	}
	if (! [srcVol readExtentsOverflowFileFromFileDescriptor:readFD error:outError]) {
		ImpPrintf(@"Failed to read extents overflow file: %@", (*outError).localizedDescription);
		return false;
	}
	if (! [srcVol readCatalogFileFromFileDescriptor:readFD error:outError]) {
		ImpPrintf(@"Failed to read catalog file: %@", (*outError).localizedDescription);
		return false;
	}

	[srcVol peekAtVolumeHeader:^(NS_NOESCAPE struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr) {
		ImpPrintf(@"Found HFS volume named “%@”", srcVol.volumeName);
		ImpPrintf(@"“%@” contains %lu files and %lu folders", srcVol.volumeName, srcVol.numberOfFiles, srcVol.numberOfFolders);
		ImpPrintf(@"Allocation block size is %lu bytes; volume has %lu blocks in use, %lu free", srcVol.numberOfBytesPerBlock, srcVol.numberOfBlocksUsed, srcVol.numberOfBlocksFree);
		ImpPrintf(@"First allocation block: 0x%llx", L(mdbPtr->drAlBlSt) * kISOStandardBlockSize);
		ImpPrintf(@"Space remaining: %u blocks (0x%llx bytes)", L(mdbPtr->drFreeBks), L(mdbPtr->drFreeBks) * L(mdbPtr->drAlBlkSiz));
		NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
		ImpPrintf(@"Volume size is %@; %@ in use, %@ free", [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksTotal], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksUsed], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksFree]);
		ImpPrintf(@"Clump size is 0x%llx (0x200 * %.1f; ABS * %.1f)", L(mdbPtr->drClpSiz), L(mdbPtr->drClpSiz) / (double)kISOStandardBlockSize, L(mdbPtr->drClpSiz) / (double)L(mdbPtr->drAlBlkSiz));
	}];

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
	__block NSUInteger lastEncounteredHeight = NSUIntegerMax;
	__block NSUInteger numNodesThisRow = 0;
	NSMutableArray <NSString *> *_Nonnull const nodeIndexStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];
	NSMutableArray <NSString *> *_Nonnull const indexNodePointerCountStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];

	NSMutableSet *_Nonnull const nodesPreviouslyEncountered = [NSMutableSet setWithCapacity:headerNode.numberOfTotalNodes];
	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if ([nodesPreviouslyEncountered containsObject:@(node.nodeNumber)]) {
			ImpPrintf(@"Walk encountered node AGAIN(???): %@", node);
			return true;
		}
		[nodesPreviouslyEncountered addObject:@(node.nodeNumber)];
		++numNodes;
		++numNodesThisRow;
		[nodeIndexStrings addObject:[NSString stringWithFormat:@"#%u", (u_int32_t)node.nodeNumber]];
		if (node.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)node;
			[indexNodePointerCountStrings addObject:[NSString stringWithFormat:@"%u", indexNode.numberOfRecords]];
		}

		NSUInteger const thisHeight = node.nodeHeight;
		if (thisHeight != lastEncounteredHeight) {
			if (lastEncounteredHeight != NSUIntegerMax) {
				ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@", "]);
				if (indexNodePointerCountStrings.count > 0) {
					ImpPrintf(@"⬇️⬇️⬇️:\t\t(%@)", [indexNodePointerCountStrings componentsJoinedByString:@", "]);
				}
			}
			lastEncounteredHeight = thisHeight;
			numNodesThisRow = 0;
			[nodeIndexStrings removeAllObjects];
			[indexNodePointerCountStrings removeAllObjects];
		}
		return true;
	}];
	if (lastEncounteredHeight != NSUIntegerMax) {
		ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@","]);
	}

	__block NSUInteger numFiles = 0, numFolders = 0, numThreads = 0;

	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		ImpPrintf(@"Walk encountered node: %@", node);

		if (node.nodeType == kBTLeafNode) {
			[node forEachCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
				ImpPrintf(@"- 📄 “%@”, ID #%u (0x%x), type %@ creator %@", [srcVol.textEncodingConverter stringForPascalString:catalogKeyPtr->nodeName], L(fileRec->fileID), L(fileRec->fileID),  NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdCreator)));
				++numFiles;
			} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
				ImpPrintf(@"- 📁 “%@” with ID #%u, %u items", [srcVol.textEncodingConverter stringForPascalString:catalogKeyPtr->nodeName], L(folderRec->folderID), L(folderRec->valence));
				++numFolders;
			} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
				u_int32_t const threadID = L(threadRec->parentID);
				ImpPrintf(@"- 🧵 with ID #%u and name %@", threadID, [srcVol.textEncodingConverter stringForPascalString:threadRec->nodeName]);
				++numThreads;
			}];
		}
		return true;
	}];
	ImpPrintf(@"Encountered %lu nodes", numNodes);
	ImpPrintf(@"Encountered %lu files, %lu folders (including root directory), %lu threads", numFiles, numFolders, numThreads);
	ImpPrintf(@"Volume header says it has %u files, %u folders (excluding root directory)", srcVol.numberOfFiles, srcVol.numberOfFolders);

	return true;
}

@end
