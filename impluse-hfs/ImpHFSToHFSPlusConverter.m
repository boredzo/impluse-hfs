//
//  ImpHFSToHFSPlusConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSToHFSPlusConverter.h"

#import <hfs/hfs_format.h>
#import <CoreServices/CoreServices.h>
#import <sys/stat.h>

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpErrorUtilities.h"
#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpMutableBTreeFile.h"
#import "ImpExtentSeries.h"
#import "ImpTextEncodingConverter.h"

///Simple data object for an item in a catalog file being translated.
@interface ImpCatalogItem: NSObject

- (instancetype _Nonnull) initWithCatalogNodeID:(HFSCatalogNodeID const)cnid;

@property HFSCatalogNodeID cnid;
@property bool needsThreadRecord;

///The key for the item's file or folder record, containing its parent item CNID and its own name. This version of the key comes from the source volume.
@property(strong) NSData *sourceKey;
///The item's file or folder record. This version of the record comes from the source volume.
@property(strong) NSData *sourceRecord;
///The key for the item's file or folder record, containing its parent item CNID and its own name. This version of the key has been converted for the destination volume.
@property(strong) NSMutableData *destinationKey;
///The item's file or folder record, converted for the destination volume.
@property(strong) NSMutableData *destinationRecord;
///The key for the item's thread record, containing its own CNID. This version of the key comes from the source volume.
@property(strong) NSData *sourceThreadKey;
///The thread record, containing the item's parent CNID and its own name. This version of the key comes from the source volume.
@property(strong) NSData *sourceThreadRecord;
///The key for the item's thread record, containing its own CNID. This version of the key has been converted for the destination volume.
@property(strong) NSMutableData *destinationThreadKey;
///The thread record, containing the item's parent CNID and its own name. This version of the key has been converted for the destination volume.
@property(strong) NSMutableData *destinationThreadRecord;

@end

///Simple data object representing one key-value pair in a B*-tree file's leaf row. Used in converting the catalog file (as thread records may need to be created for files that don't have them, and these thread records will need to be inserted into the list of records in a way that preserves the ordering of keys).
@interface ImpCatalogKeyValuePair : NSObject

- (instancetype _Nonnull)initWithKey:(NSData *_Nonnull const)keyData value:(NSData *_Nonnull const)valueData;

@property(strong) NSData *key;
@property(strong) NSData *value;

@end

///Pared-down substitute for ImpBTreeNode, which needs to be backed by a complete tree. This is used in making a new tree.
@interface ImpMockNode : NSObject

///Create an ImpMockNode that can hold maxNumBytes' worth of records.
- (instancetype) initWithCapacity:(u_int32_t const)maxNumBytes;

///The index of this node, starting from 0. This node should never be given the index 0 (and, since it defaults to 0, it must be changed) since that's the index of the header node, and ImpMockNodes never represent a header node.
@property u_int32_t nodeNumber;

///The height of this row in the B*-tree. The header row (header node and map nodes) has no height; nodes in that row have height 0. The leaf row is always at height 1, and index rows are at increasing heights above that.
@property u_int8_t nodeHeight;

///The first key that has been added to this node, if any. (Used for building index nodes from the first key of each node on the row below.)
@property(nonatomic, readonly) NSData *_Nullable firstKey;

///Returns the total size of all records in the node (that is, all keys plus all associated payloads).
@property(readonly) u_int32_t totalSizeOfAllRecords;

///Append a key to the node's list of records.
- (bool) appendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData;

- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode;

@end
@interface ImpMockIndexNode : ImpMockNode

///Append a key to the node's list of pointer records, linked to the provided node.
- (bool) appendKey:(NSData *_Nonnull const)keyData fromNode:(ImpMockNode *_Nonnull const)descendantNode;

///Add records to a real index node to match the contents of this mock index node.
- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode;

@end

@implementation ImpHFSToHFSPlusConverter
{
	TextEncoding _hfsTextEncoding, _hfsPlusTextEncoding;
	TextToUnicodeInfo _ttui;
}

- (instancetype _Nonnull)init {
	if ((self = [super init])) {
		_hfsTextEncoding = kTextEncodingMacRoman; //TODO: Should expose this as a setting, since HFS volumes themselves don't declare what encoding they used as far as I could find
		//TODO: Even for MacRoman, it may make sense to expose a choice between kMacRomanCurrencySignVariant and kMacRomanEuroSignVariant. (Also maybe auto-detect based on volume creation date? Euro sign variant came in with Mac OS 8.5.)
		_hfsTextEncoding = CreateTextEncoding(kTextEncodingMacRoman, kMacRomanDefaultVariant, kTextEncodingDefaultFormat);
		_hfsPlusTextEncoding = CreateTextEncoding(kTextEncodingUnicodeV2_0, kUnicodeHFSPlusDecompVariant, kUnicodeUTF16BEFormat);

		struct UnicodeMapping mapping = {
			.unicodeEncoding = _hfsPlusTextEncoding,
			.otherEncoding = _hfsTextEncoding,
			.mappingVersion = kUnicodeUseHFSPlusMapping,
		};
		OSStatus const err = CreateTextToUnicodeInfo(&mapping, &_ttui);
		if (err != noErr) {
			ImpPrintf(@"Failed to initialize Unicode conversion: error %d/%s", err, ImpExplainOSStatus(err));
		}
	}
	return self;
}

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull)pascalString {
	//The length in MacRoman characters may include accented characters that HFS+ decomposition will decompose to a base character and a combining character, so we actually need to double the length *in characters*.
	ByteCount outputPayloadSizeInBytes = (2 * *pascalString) * sizeof(UniChar);
	//TECConvertText documentation: “Always allocate a buffer at least 32 bytes long.”
	if (outputPayloadSizeInBytes < 32) {
		outputPayloadSizeInBytes = 32;
	}
	ByteCount const outputBufferSizeInBytes = outputPayloadSizeInBytes + 1 * sizeof(UniChar);
	NSMutableData *_Nonnull const unicodeData = [NSMutableData dataWithLength:outputBufferSizeInBytes];

	if (*pascalString == 0) {
		//TEC doesn't like converting empty strings, so just return our empty HFSUniStr255 without calling TEC.
		return unicodeData;
	}

	UniChar *_Nonnull const outputBuf = unicodeData.mutableBytes;

	ByteCount actualOutputLengthInBytes = 0;
	OSStatus const err = ConvertFromPStringToUnicode(_ttui, pascalString, outputPayloadSizeInBytes, &actualOutputLengthInBytes, outputBuf + 1);

	if (err != noErr) {
		NSMutableData *_Nonnull const cStringData = [NSMutableData dataWithLength:pascalString[0]];
		char *_Nonnull const cStringBytes = cStringData.mutableBytes;
		memcpy(cStringBytes, pascalString + 1, *pascalString);
		ImpPrintf(@"Failed to convert filename '%s' (length %u) to Unicode: error %d/%s", (char const *)cStringBytes, (unsigned)*pascalString, err, ImpExplainOSStatus(err));
		if (err == kTECOutputBufferFullStatus) {
			ImpPrintf(@"Output buffer fill: %lu vs. buffer size %lu", (unsigned long)actualOutputLengthInBytes, outputPayloadSizeInBytes);
		}
		return nil;
	} else {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
		//Swap all the bytes in the output data.
		swab(outputBuf + 1, outputBuf + 1, actualOutputLengthInBytes);
#endif
	}
	S(outputBuf[0], (u_int16_t)(actualOutputLengthInBytes / sizeof(UniChar)));

	return unicodeData;
}
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull)pascalString {
	NSData *_Nonnull const unicodeData = [self hfsUniStr255ForPascalString:pascalString];
	/* This does not seem to work.
	 hfsUniStr255ForPascalString: needs to return UTF-16 BE so we can write it out to HFS+. But if we call CFStringCreateWithPascalString, it seems to always take the host-least-significant byte and treat it as a *byte count*. That basically means this always returns an empty string. If the length is unswapped, it returns the first half of the string.
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, unicodeData.bytes, kCFStringEncodingUTF16BE);
	 */
	CFIndex const numCharacters = L(*(UniChar *)unicodeData.bytes);
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, unicodeData.bytes + sizeof(UniChar), numCharacters * sizeof(UniChar), kCFStringEncodingUTF16BE, /*isExternalRep*/ false);
	return unicodeString;
}

- (void) reportSourceBlocksCopied:(NSUInteger const)thisManyMore {
	self.numberOfSourceBlocksCopied = self.numberOfSourceBlocksCopied + thisManyMore;
}
- (void) reportSourceExtentRecordCopied:(struct HFSExtentDescriptor const *_Nonnull const)extRecPtr {
	[self reportSourceBlocksCopied:ImpNumberOfBlocksInHFSExtentRecord(extRecPtr)];
}

- (void) deliverProgressUpdate:(double)progress
	operationDescription:(NSString *_Nonnull)operationDescription
{
	if (self.conversionProgressUpdateBlock != nil) {
		self.conversionProgressUpdateBlock(progress, operationDescription);
	}
}

- (void) deliverProgressUpdateWithOperationDescription:(NSString *_Nonnull)operationDescription
{
	[self deliverProgressUpdate:self.numberOfSourceBlocksCopied / (double)self.numberOfSourceBlocksToCopy operationDescription:operationDescription];
}

///Note that this does not strictly give a _logical_ file size (as in, length in bytes) because that can't be derived from a block count. This is an upper bound on the logical file size. Still, if we don't have the logical file size and computing it would be non-trivial (e.g., require computing the total size of all nodes in a B*-tree), this is the next best thing and hopefully not too problematic.
- (u_int64_t) estimateFileSizeFromExtentSeries:(ImpExtentSeries *_Nonnull const)series {
	__block u_int64_t total = 0;
	[series forEachExtent:^(struct HFSPlusExtentDescriptor const *_Nonnull const extDesc) {
		total += L(extDesc->blockCount) * kISOStandardBlockSize;
	}];

	return total;
}

- (u_int64_t) encodingsBitmapWithOneTextEncoding:(TextEncoding const)hfsTextEncoding {
	u_int64_t shiftDistance = 0;
	if (hfsTextEncoding < 64) {
		shiftDistance = hfsTextEncoding;
	} else {
		//Substitutions per TN1150.
		if (hfsTextEncoding == kTextEncodingMacUkrainian) {
			return 48;
		} else if (hfsTextEncoding == kTextEncodingMacFarsi) {
			return 49;
		}
	}
	return ((u_int64_t)1) << shiftDistance;
}

- (void) convertHFSVolumeHeader:(struct HFSMasterDirectoryBlock const *_Nonnull const)mdbPtr toHFSPlusVolumeHeader:(struct HFSPlusVolumeHeader *_Nonnull const)vhPtr
{
	struct HFSPlusVolumeHeader vh = {
		.signature = CFSwapInt16HostToBig(kHFSPlusSigWord),
		.version = CFSwapInt16HostToBig(kHFSPlusVersion),
		.attributes = 0, //mdbPtr->drAtrb (see below)
		.lastMountedVersion = CFSwapInt32HostToBig('8.10'),
		.journalInfoBlock = 0,
		.createDate = mdbPtr->drCrDate,
		.modifyDate = mdbPtr->drLsMod,
		.backupDate = mdbPtr->drVolBkUp,
		.checkedDate = 0,
		.fileCount = mdbPtr->drFilCnt,
		.folderCount = mdbPtr->drDirCnt,
		.blockSize = mdbPtr->drAlBlkSiz,
		.totalBlocks = mdbPtr->drNmAlBlks,
		.freeBlocks = mdbPtr->drFreeBks,
		.nextAllocation = mdbPtr->drAllocPtr,
		.rsrcClumpSize = mdbPtr->drClpSiz,
		.dataClumpSize = mdbPtr->drClpSiz,
		.nextCatalogID = mdbPtr->drNxtCNID,
		.writeCount = mdbPtr->drWrCnt,
		.encodingsBitmap = 0,
		.finderInfo = { 0 }, //mdbPtr->drFndrInfo,
	};
	//TODO: Can we get away with just copying the volume's Finder info verbatim? The size is the same, but are all the fields the same? (IM:F doesn't elaborate on the on-disk volume Finder info format, unfortunately.)
	memcpy(&(vh.finderInfo), &(mdbPtr->drFndrInfo), 8 * sizeof(u_int32_t));

	//There are only four attributes allowed on a valid HFS volume according to IM:F. Clear everything else.
	S(vh.attributes, L(mdbPtr->drAtrb) & kHFSMDBAttributesMask);
	S(vh.encodingsBitmap, [self encodingsBitmapWithOneTextEncoding:self.hfsTextEncoding]);

	//Translate the VBM into the allocation file, and the extents and catalog files into their HFS+ counterparts.
	//The VBM is implied by IM:F to be necessarily contiguous (only the catalog and extents overflow files are expressly not), and is guaranteed to always be at block #3 in HFS. On HFS+, the VBM isn't necessarily contiguous.
	//The VBM (at least in HFS+) indicates the allocation state of the entire volume, so its length in bits is the number of allocation blocks for the whole volume. Divide by eight to get bytes, and then by the allocation block size to get blocks.
	u_int32_t const numABlocks = L(mdbPtr->drNmAlBlks);
	u_int16_t const allocationFileSizeInBytes = (u_int16_t)((numABlocks + 7) / 8); //drNmAlBlks is u_int16_t; we don't need to go any bigger than that for the result of this computation.
	u_int16_t const allocationFileSizeInBlocks = allocationFileSizeInBytes / L(vh.blockSize);
	S(vh.allocationFile.totalBlocks, allocationFileSizeInBlocks);
	vh.allocationFile.clumpSize = mdbPtr->drClpSiz;
	//DiskWarrior seems to be of the opinion that the logical length should be equal to the physical length (total size of occupied blocks). TN1150 says this is allowed, but doesn't say it's necessary.
//	S(vh.allocationFile.logicalSize, allocationFileSizeInBytes);
	S(vh.allocationFile.logicalSize, allocationFileSizeInBlocks * L(vh.blockSize));
	vh.allocationFile.extents[0].startBlock = mdbPtr->drVBMSt;
	vh.allocationFile.extents[0].blockCount = vh.allocationFile.totalBlocks;

	vh.catalogFile.clumpSize = mdbPtr->drCTClpSiz;
	/*Does not make sense in a defragmenting conversion.
	vh.catalogFile.totalBlocks = mdbPtr->drCTFlSize;
	ImpExtentSeries *_Nonnull const catExtentSeries = [ImpExtentSeries new];
	[catExtentSeries appendHFSExtentRecord:mdbPtr->drCTExtRec];
	[catExtentSeries getHFSPlusExtentRecordAtIndex:0 buffer:vh.catalogFile.extents];
	vh.catalogFile.logicalSize = [self estimateFileSizeFromExtentSeries:catExtentSeries];
	 */

	vh.extentsFile.clumpSize = mdbPtr->drXTClpSiz;
	/*Does not make sense in a defragmenting conversion.
	vh.extentsFile.totalBlocks = mdbPtr->drXTFlSize;
	ImpExtentSeries *_Nonnull const extExtentSeries = [ImpExtentSeries new];
	[extExtentSeries appendHFSExtentRecord:mdbPtr->drXTExtRec];
	[extExtentSeries getHFSPlusExtentRecordAtIndex:0 buffer:vh.extentsFile.extents];
	vh.extentsFile.logicalSize = [self estimateFileSizeFromExtentSeries:extExtentSeries];
	 */

	/*Not copied:
	 * drNmFls (number of files in root folder—different from drFilCnt, which is fileCount in HFS+)
	 * drVBMSt (always 3, and HFS+ stores the VBM as a file)
	 * drAlBlSt
	 * drVN (extract to wherever HFS+ stores it—maybe the name of the root directory?)
	 * drVSeqNum
	 * drXTClpSiz
	 * drCTClpSiz
	 * drNmRtDirs
	 * drEmbedSigWord (used by HFS+ wrapper volumes)/drVCSize (used by File Manager)
	 * drEmbedExtent (used by HFS+ wrapper volumes)/drVBMCSize and drCtlCSize (used by File Manager)
	 *
	 *Also needed:
	 * allocationFile (must be assembled from volume bitmap starting at drVBMSt, or regenerated if we don't maintain file allocation locations)
	 * extentsFile (will likely involve drXTFlSize and drXTExtRec)
	 * catalogFile (will likely involve drCTFlSize and drCTExtRec)
	 * attributesFile
	 * startupFile
	 */

	memcpy(vhPtr, &vh, sizeof(vh));
}

- (bool) performConversionOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	return (
		true
		&& [self step0_preflight_error:outError]
		&& [self step1_convertPreamble_error:outError]
		&& [self step2_convertVolume_error:outError]
		&& [self step3_flushVolume_error:outError]
	);
}

#pragma mark Conversion utilities

///We don't actually need to zero anything in the methods that use this macro since they're writing into storage created by an NSMutableData, which already zeroed it for us. This macro basically exists to acknowledge reserved fields so they don't look like they were forgotten.
#define ImpZeroField(dst) /*do nothing*/

- (NSUInteger) convertHFSCatalogKey:(struct HFSCatalogKey const *_Nonnull const)srcKeyPtr toHFSPlus:(struct HFSPlusCatalogKey *_Nonnull const)dstKeyPtr
{
	ImpTextEncodingConverter *_Nonnull const tec = self.sourceVolume.textEncodingConverter;
	struct HFSUniStr255 *_Nonnull const unicodeNamePtr = &(dstKeyPtr->nodeName);
	if (! [tec convertPascalString:srcKeyPtr->nodeName intoHFSUniStr255:unicodeNamePtr bufferSize:sizeof(dstKeyPtr->nodeName)]) {
		//TODO: Return an error here
		NSAssert(false, @"Failed to convert key's node name to HFSUniStr255: %@", CFStringCreateWithPascalStringNoCopy(kCFAllocatorDefault, srcKeyPtr->nodeName, kCFStringEncodingMacRoman, /*deallocator*/ kCFAllocatorNull));
		return 0;
	}
	S(dstKeyPtr->parentID, L(srcKeyPtr->parentID));

	u_int16_t const keyLength = (
		0 //Size of the keyLength field is omitted here.
		+ sizeof(dstKeyPtr->parentID)
		+ sizeof(dstKeyPtr->nodeName.length)
		+ (sizeof(dstKeyPtr->nodeName.unicode[0]) * L(dstKeyPtr->nodeName.length))
	);
	S(dstKeyPtr->keyLength, keyLength);
	return keyLength + sizeof(keyLength);
}

- (NSMutableData *_Nonnull) convertHFSCatalogKeyToHFSPlus:(NSData *_Nonnull const)sourceKeyData {
	NSParameterAssert(sourceKeyData.length == sizeof(struct HFSCatalogKey));

	NSMutableData *_Nonnull const dstKeyData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogKey)];
	struct HFSCatalogKey const *_Nonnull const srcKeyPtr = sourceKeyData.bytes;
	struct HFSPlusCatalogKey *_Nonnull const dstKeyPtr = dstKeyData.mutableBytes;

	NSUInteger const keyLengthIncludingLengthField = [self convertHFSCatalogKey:srcKeyPtr toHFSPlus:dstKeyPtr];
	[dstKeyData setLength:keyLengthIncludingLengthField];

	return dstKeyData;
}
- (NSMutableData *_Nonnull) convertHFSCatalogFileRecordToHFSPlus:(NSData *_Nonnull const)sourceRecData {
	NSParameterAssert(sourceRecData.length == sizeof(struct HFSCatalogFile));

	NSMutableData *_Nonnull const destRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogFile)];
	struct HFSCatalogFile const *_Nonnull const srcFilePtr = sourceRecData.bytes;
	struct HFSPlusCatalogFile *_Nonnull const destFilePtr = destRecData.mutableBytes;

	S(destFilePtr->recordType, kHFSPlusFileRecord);
	//TODO: Files coming from HFS will probably not have thread records; for each such file, we'll need to create a thread record and then set kHFSThreadExistsMask here.
	S(destFilePtr->flags, L(srcFilePtr->flags));
	ImpZeroField(destFilePtr->reserved1);
	S(destFilePtr->fileID, L(srcFilePtr->fileID));
	S(destFilePtr->createDate, L(srcFilePtr->createDate));
	S(destFilePtr->contentModDate, L(srcFilePtr->modifyDate));
	//TN1150 on attributeModDate: “The last date and time that any field in the file's catalog record was changed. An implementation may treat this field as reserved. In Mac OS X, the BSD APIs use this field as the file's change time (returned in the st_ctime field of struct stat). All versions of Mac OS 8 and 9 treat this field as reserved.”
	ImpZeroField(destFilePtr->attributeModDate);
	//TN1150 on accessDate: “The traditional Mac OS implementation of HFS Plus does not maintain the accessDate field. Files created by traditional Mac OS have an accessDate of zero.”
	ImpZeroField(destFilePtr->accessDate);
	S(destFilePtr->backupDate, L(srcFilePtr->backupDate));

	//TN1150 on bsdInfo (which it calls “permissions”): “The traditional Mac OS implementation of HFS Plus does not use the permissions field. Files created by traditional Mac OS have the entire field set to 0.”
	ImpZeroField(destFilePtr->bsdInfo);
	memcpy(&destFilePtr->userInfo, &srcFilePtr->userInfo, sizeof(destFilePtr->userInfo));
	memcpy(&destFilePtr->finderInfo, &srcFilePtr->finderInfo, sizeof(destFilePtr->finderInfo));

	S(destFilePtr->textEncoding, self.hfsTextEncoding);
	ImpZeroField(destFilePtr->reserved2);

	//Don't convert extents (those will be populated when we copy the fork data), but do convert the logical sizes.
	S(destFilePtr->dataFork.logicalSize, srcFilePtr->dataLogicalSize);
	S(destFilePtr->resourceFork.logicalSize, srcFilePtr->rsrcLogicalSize);
	//Per-fork clump sizes were unused prior to 10.3 and are used for something else since 10.3, so don't bother storing anything there. Leave it zero.
	//totalBlocks is the HFS+ version of {data,rsrc}PhysicalSize, but meaningless since the allocation block size may have changed. Recompute those as part of copying.

	return destRecData;
}
- (NSMutableData *_Nonnull) convertHFSCatalogFolderRecordToHFSPlus:(NSData *_Nonnull const)sourceRecData {
	NSParameterAssert(sourceRecData.length == sizeof(struct HFSCatalogFolder));

	NSMutableData *_Nonnull const destRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogFolder)];
	struct HFSCatalogFolder const *_Nonnull const srcFolderPtr = sourceRecData.bytes;
	struct HFSPlusCatalogFolder *_Nonnull const destFolderPtr = destRecData.mutableBytes;

	S(destFolderPtr->recordType, kHFSPlusFolderRecord);
	S(destFolderPtr->flags, L(srcFolderPtr->flags));
	S(destFolderPtr->valence, L(srcFolderPtr->valence));
	S(destFolderPtr->folderID, L(srcFolderPtr->folderID));
	S(destFolderPtr->createDate, L(srcFolderPtr->createDate));
	S(destFolderPtr->contentModDate, L(srcFolderPtr->modifyDate));
	//TN1150 on attributeModDate: “The last date and time that any field in the folder's catalog record was changed. An implementation may treat this field as reserved. In Mac OS X, the BSD APIs use this field as the folder's change time (returned in the st_ctime field of struct stat). All versions of Mac OS 8 and 9 treat this field as reserved.”
	ImpZeroField(destFolderPtr->attributeModDate);
	//TN1150 on accessDate: “The traditional Mac OS implementation of HFS Plus does not maintain the accessDate field. Folders created by traditional Mac OS have an accessDate of zero.”
	ImpZeroField(destFolderPtr->accessDate);
	S(destFolderPtr->backupDate, L(srcFolderPtr->backupDate));

	//TN1150 on bsdInfo (which it calls “permissions”): “The traditional Mac OS implementation of HFS Plus does not use the permissions field. Folders created by traditional Mac OS have the entire field set to 0.”
	ImpZeroField(destFolderPtr->bsdInfo);
	memcpy(&destFolderPtr->userInfo, &srcFolderPtr->userInfo, sizeof(destFolderPtr->userInfo));
	memcpy(&destFolderPtr->finderInfo, &srcFolderPtr->finderInfo, sizeof(destFolderPtr->finderInfo));

	//TODO: Get the encoding from the source volume, which really should have a property for that by now.
	//TODO: Also, need to set this bit in the encoding bitmap and make sure we set that in the volume header.
	S(destFolderPtr->textEncoding, kTextEncodingMacRoman);
	//TN1150 doesn't say anything about folderCount; hfs_format.h says it's only used when the HasFolderCount flag is set (which it isn't, because it didn't exist on HFS). That mechanism is only used by HFSX; we aren't going to use it on original HFS+.
	ImpZeroField(destFolderPtr->folderCount);

	return destRecData;
}

- (NSMutableData *_Nonnull) convertHFSCatalogThreadRecordToHFSPlus:(NSData *_Nonnull const)sourceRecData {
	NSParameterAssert(sourceRecData.length == sizeof(struct HFSCatalogThread));

	NSMutableData *_Nonnull const destRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogThread)];
	struct HFSCatalogThread const *_Nonnull const srcThreadPtr = sourceRecData.bytes;
	struct HFSPlusCatalogThread *_Nonnull const destThreadPtr = destRecData.mutableBytes;

	ImpTextEncodingConverter *_Nonnull const tec = self.sourceVolume.textEncodingConverter;
	if (! [tec convertPascalString:srcThreadPtr->nodeName intoHFSUniStr255:&(destThreadPtr->nodeName) bufferSize:sizeof(destThreadPtr->nodeName)]) {
		return nil;
	}

	S(destThreadPtr->recordType, L(srcThreadPtr->recordType) == kHFSFolderThreadRecord ? kHFSPlusFolderThreadRecord : kHFSPlusFileThreadRecord);
	ImpZeroField(destThreadPtr->reserved);
	destThreadPtr->parentID = srcThreadPtr->parentID; //Not swapped because we're copying as-is

	u_int32_t const threadRecSize = sizeof(destThreadPtr->recordType) + sizeof(destThreadPtr->reserved) + sizeof(destThreadPtr->parentID) + sizeof(destThreadPtr->nodeName.length) + sizeof(UniChar) * L(destThreadPtr->nodeName.length);
	[destRecData setLength:threadRecSize];

	return destRecData;
}

- (void) copyFromHFSCatalogFile:(ImpBTreeFile *_Nonnull const)sourceTree toHFSPlusCatalogFile:(ImpMutableBTreeFile *_Nonnull const)destTree
{
	/*We can't just convert leaf records straight across in the same order, for three reasons:
	 *- For files, we probably need to add a thread record (optional in HFS, mandatory in HFS+).
	 *- File thread records may be at a very different position in the leaf row from the corresponding file record, because the file thread record's key has the file ID as its “parent ID”, whereas the file record's key has the actual parent (directory) of the file. These are two different CNIDs and cannot be assumed to be anywhere near each other in the number sequence.
	 *- The order of names (and therefore items) may change between HFS's MacRoman-ish 8-bit encoding and HFS+'s Unicode flavor. This not only changes the leaf row, it can also ripple up into the index.
	 *
	 *We need to grab the keys, the source file or folder records, and the source thread records, and generate a list of items. Each item has a converted file or folder record with corresponding key, and a converted or generated thread record and corresponding key. From these items, we can extract both records and put those key-value pairs into a sorted array, and then use that array to populate the converted leaf row.
	 */
	NSUInteger const numItems = self.sourceVolume.numberOfFiles + self.sourceVolume.numberOfFolders;
	NSMutableDictionary <NSNumber *, ImpCatalogItem *> *_Nonnull const sourceItemsByCNID = [NSMutableDictionary dictionaryWithCapacity:numItems];
	NSMutableSet <ImpCatalogItem *> *_Nonnull const sourceItemsThatNeedThreadRecords = [NSMutableSet setWithCapacity:numItems];
	NSMutableArray <ImpCatalogItem *> *_Nonnull const allSourceItems = [NSMutableArray arrayWithCapacity:numItems];

	__block HFSCatalogNodeID largestCNIDYet = 0;
	__block HFSCatalogNodeID firstUnusedCNID = 0;

	//Gather our list of all items, converting file, folder, and thread records as we go and keeping each item's file/folder record and thread record (if it has one) together.
	[sourceTree walkLeafNodes:^bool(ImpBTreeNode *const  _Nonnull node) {
		[node forEachHFSCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRecPtr) {
			HFSCatalogNodeID const cnid = L(fileRecPtr->fileID);
			if (cnid > largestCNIDYet) {
				largestCNIDYet = cnid;
				if (firstUnusedCNID == 0 && cnid - 1 > largestCNIDYet) {
					firstUnusedCNID = largestCNIDYet + 1;
				}
			}

			ImpCatalogItem *_Nullable item = sourceItemsByCNID[@(cnid)];
			if (item == nil) {
				item = [[ImpCatalogItem alloc] initWithCatalogNodeID:cnid];
				sourceItemsByCNID[@(cnid)] = item;
				[allSourceItems addObject:item];
				[sourceItemsThatNeedThreadRecords addObject:item];
			}

			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)fileRecPtr length:sizeof(struct HFSCatalogFile) freeWhenDone:false];
			item.sourceKey = sourceKeyData;
			item.sourceRecord = sourceRecData;
			item.destinationKey = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			item.destinationRecord = [self convertHFSCatalogFileRecordToHFSPlus:sourceRecData];
		} folder:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRecPtr) {
			HFSCatalogNodeID const cnid = L(folderRecPtr->folderID);
			if (cnid > largestCNIDYet) {
				largestCNIDYet = cnid;
				if (firstUnusedCNID == 0 && cnid - 1 > largestCNIDYet) {
					firstUnusedCNID = largestCNIDYet + 1;
				}
			}

			ImpCatalogItem *_Nullable item = sourceItemsByCNID[@(cnid)];
			if (item == nil) {
				item = [[ImpCatalogItem alloc] initWithCatalogNodeID:cnid];
				sourceItemsByCNID[@(cnid)] = item;
				[allSourceItems addObject:item];
				[sourceItemsThatNeedThreadRecords addObject:item];
			}

			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)folderRecPtr length:sizeof(struct HFSCatalogFolder) freeWhenDone:false];
			item.sourceKey = sourceKeyData;
			item.sourceRecord = sourceRecData;
			item.destinationKey = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			item.destinationRecord = [self convertHFSCatalogFolderRecordToHFSPlus:sourceRecData];
		} thread:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRecPtr) {
			HFSCatalogNodeID const cnid = L(catalogKeyPtr->parentID);
			if (cnid > largestCNIDYet) largestCNIDYet = cnid;

			ImpCatalogItem *_Nullable item = sourceItemsByCNID[@(cnid)];
			if (item == nil) {
				item = [[ImpCatalogItem alloc] initWithCatalogNodeID:cnid];
				sourceItemsByCNID[@(cnid)] = item;
				[allSourceItems addObject:item];
			} else {
				[sourceItemsThatNeedThreadRecords removeObject:item];
			}

			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)threadRecPtr length:sizeof(struct HFSCatalogThread) freeWhenDone:false];
			item.sourceThreadKey = sourceKeyData;
			item.sourceThreadRecord = sourceRecData;
			item.destinationThreadKey = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			item.destinationThreadRecord = [self convertHFSCatalogThreadRecordToHFSPlus:sourceRecData];
			item.needsThreadRecord = false;
		}];
		return true;
	}];

	//Now we have all the items. HFS requires folders to have thread records, so those should all have them, but files having thread records was optional (but is required under HFS+), so we may need to create those.
	for (ImpCatalogItem *_Nonnull const item in sourceItemsThatNeedThreadRecords) {
		if (item.needsThreadRecord) {
			NSMutableData *_Nonnull const threadKeyData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogKey)];
			struct HFSPlusCatalogKey *_Nonnull const threadKeyPtr = threadKeyData.mutableBytes;
			NSMutableData *_Nonnull const threadRecData = [NSMutableData dataWithLength:sizeof(struct HFSPlusCatalogThread)];
			struct HFSPlusCatalogThread *_Nonnull const threadRecPtr = threadRecData.mutableBytes;

			NSData *_Nonnull const keyData = item.destinationKey;
			struct HFSPlusCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
			NSData *_Nonnull const recData = item.destinationRecord;
			void const *_Nonnull const recPtr = recData.bytes;
			int16_t const *_Nonnull const recTypePtr = recPtr;
			struct HFSPlusCatalogFile const *_Nonnull const filePtr = recPtr;
			struct HFSPlusCatalogFolder const *_Nonnull const folderPtr = recPtr;

			//In a thread record, the key holds the item's *own* ID (despite being called “parentID”) and an empty name, while the thread record holds the item's *parent*'s ID and the item's own name.
			switch (L(*recTypePtr)) {
				case kHFSPlusFileRecord:
					threadKeyPtr->parentID = filePtr->fileID;
					S(threadRecPtr->recordType, kHFSPlusFileThreadRecord);
					break;
				case kHFSPlusFolderRecord:
					//Technically we shouldn't get here, either, as thread records were required for folders under HFS.
					threadKeyPtr->parentID = folderPtr->folderID;
					S(threadRecPtr->recordType, kHFSPlusFolderThreadRecord);
					break;
				default:
					__builtin_unreachable();
			}
			threadRecPtr->parentID = keyPtr->parentID;
			memcpy(&threadRecPtr->nodeName, &keyPtr->nodeName, sizeof(threadRecPtr->nodeName));
			//DiskWarrior complains about “oversized thread records” if the thread payload contains empty space. Plus, shrinking these down frees up space in the node for more records.
			u_int32_t const threadRecSize = sizeof(threadRecPtr->recordType) + sizeof(threadRecPtr->reserved) + sizeof(threadRecPtr->parentID) + sizeof(threadRecPtr->nodeName.length) + sizeof(UniChar) * L(threadRecPtr->nodeName.length);
			[threadRecData setLength:threadRecSize];

			//A thread key has a CNID and an empty node name (so, length 0). keyLength doesn't include itself.
			u_int16_t const threadKeySize = sizeof(threadKeyPtr->keyLength) + sizeof(threadKeyPtr->parentID) + sizeof(threadKeyPtr->nodeName.length);
			u_int16_t const threadKeyLength = threadKeySize - sizeof(threadKeyPtr->keyLength);
			S(threadKeyPtr->keyLength, threadKeyLength);
			[threadKeyData setLength:threadKeySize];

			item.destinationThreadKey = threadKeyData;
			item.destinationThreadRecord = threadRecData;
			item.needsThreadRecord = false;
		}
	}

	//Now all of our items have both a file or folder record and a thread record. Each of these is filed under a different key in the catalog file, due to their different purposes. (File and folder records are stored under a key containing their parent item's CNID; thread records are stored under a key containing the item's own CNID, for the purpose of finding the parent ID stored in the thread record.) So turn our list of n items into n * 2 key-value pairs, half of them being file or folder records and half being thread records. These will be the contents of the leaf row.
	NSMutableArray <ImpCatalogKeyValuePair *> *_Nonnull const keyValuePairs = [NSMutableArray arrayWithCapacity:allSourceItems.count];
	for (ImpCatalogItem *_Nonnull const item in allSourceItems) {
		[keyValuePairs addObject:[[ImpCatalogKeyValuePair alloc] initWithKey:item.destinationKey value:item.destinationRecord]];
		ImpPrintf(@"Main record: %lu + %lu = %lu bytes", item.destinationKey.length, item.destinationRecord.length, item.destinationKey.length + item.destinationRecord.length);
		[keyValuePairs addObject:[[ImpCatalogKeyValuePair alloc] initWithKey:item.destinationThreadKey value:item.destinationThreadRecord]];
		ImpPrintf(@"Thread record: %lu + %lu = %lu bytes", item.destinationThreadKey.length, item.destinationThreadRecord.length, item.destinationThreadKey.length + item.destinationThreadRecord.length);
	}
	[keyValuePairs sortUsingSelector:@selector(caseInsensitiveCompare:)];

	/*The algorithm for building the index is built around a loop that processes an entire row and produces a new row above the previous one.
	 *The initial row is the leaf row; each row produced above it is an index row.
	 *The first key from each node on the lower row is appended to the upper row, adding new nodes on the upper row as needed.
	 *Each round of the loop produces a significantly shorter row. (I haven't done the math but my intuitive sense is that it's an exponential curve following the approximate average number of keys per index node.) Every row will contain the first key in the leaf row, fulfilling that requirement.
	 *The loop ends when the upper row has been fully populated in one node. That node is the root node.
	 */
	u_int32_t const nodeBodySize = destTree.bytesPerNode - (sizeof(struct BTNodeDescriptor) + sizeof(BTreeNodeOffset));

	//First, fill out the bottom row with mock leaf nodes. Each “mock node” is an array of NSDatas representing catalog keys; we separately track the total size of the pointer records (each of which is a key + a u_int32_t), so that when adding another key would exceed the capacity of a real node (nodeBodySize), we tear off that node and start the next one.
	NSMutableArray <ImpMockNode *> *_Nonnull const bottomRow = [NSMutableArray arrayWithCapacity:allSourceItems.count];
	ImpMockNode *_Nullable thisMockNode = nil;

	u_int32_t numLiveNodes = 1; //1 for the header node

	for (ImpCatalogKeyValuePair *_Nonnull const kvp in keyValuePairs) {
		if (thisMockNode == nil) {
			thisMockNode = [[ImpMockNode alloc] initWithCapacity:nodeBodySize];
			thisMockNode.nodeHeight = 1;
			[bottomRow addObject:thisMockNode];
			++numLiveNodes;
		}

		if (! [thisMockNode appendKey:kvp.key payload:kvp.value]) {
			thisMockNode = [[ImpMockNode alloc] initWithCapacity:nodeBodySize];
			thisMockNode.nodeHeight = 1;
			[bottomRow addObject:thisMockNode];
			++numLiveNodes;

			NSAssert([thisMockNode appendKey:kvp.key payload:kvp.value], @"Encountered catalog entry too big to fit in a catalog node: Key is %lu bytes, payload is %lu bytes, but maximal node capacity is %u bytes", kvp.key.length, kvp.value.length, nodeBodySize);
		}
	}

	NSMutableArray <NSArray <ImpMockNode *> *> *_Nonnull const mockRows = [NSMutableArray arrayWithCapacity:sourceTree.headerNode.treeDepth];
	NSMutableArray <ImpMockIndexNode *> *_Nonnull const allMockIndexNodes = [NSMutableArray arrayWithCapacity:allSourceItems.count];
	[mockRows addObject:bottomRow];

	while (mockRows.firstObject.count > 1) {
		NSMutableArray <ImpMockIndexNode *> *_Nonnull upperRow = [NSMutableArray arrayWithCapacity:keyValuePairs.count];
		ImpMockIndexNode *_Nullable indexNodeInProgress = nil;

		NSArray <ImpMockNode *> *_Nonnull const lowerRow = mockRows.firstObject;
		for (ImpMockNode *_Nonnull const node in lowerRow) {
			if (indexNodeInProgress == nil) {
				indexNodeInProgress = [[ImpMockIndexNode alloc] initWithCapacity:nodeBodySize];
				indexNodeInProgress.nodeHeight = (u_int8_t)(mockRows.count + 1);
				[upperRow addObject:indexNodeInProgress];
				++numLiveNodes;
			}

			NSData *_Nonnull const keyData = node.firstKey;
			if (! [indexNodeInProgress appendKey:keyData fromNode:node]) {
				indexNodeInProgress = [[ImpMockIndexNode alloc] initWithCapacity:nodeBodySize];
				indexNodeInProgress.nodeHeight = (u_int8_t)(mockRows.count + 1);
				[upperRow addObject:indexNodeInProgress];
				++numLiveNodes;

				NSAssert([indexNodeInProgress appendKey:keyData fromNode:node], @"Encountered catalog entry too big to fit in a catalog index node: Key is %lu bytes, payload is %lu bytes, but maximal node capacity is %u bytes (%u already used)", keyData.length, sizeof(u_int32_t), nodeBodySize, indexNodeInProgress.totalSizeOfAllRecords);
			}
		}

		[allMockIndexNodes addObjectsFromArray:upperRow];
		[mockRows insertObject:upperRow atIndex:0];
	}

	//Start creating real nodes.
	NSMutableArray <ImpBTreeNode *> *_Nonnull const allRealIndexNodes = [NSMutableArray arrayWithCapacity:allMockIndexNodes.count];
	for (ImpMockIndexNode *_Nonnull const mockIndexNode in allMockIndexNodes) {
		ImpBTreeNode *_Nonnull const realIndexNode = [destTree allocateNewNodeOfKind:kBTIndexNode populate:^(void * _Nonnull bytes, NSUInteger length) {
			struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
			nodeDesc->height = mockIndexNode.nodeHeight;
		}];
		[allRealIndexNodes addObject:realIndexNode];
		mockIndexNode.nodeNumber = realIndexNode.nodeNumber;
	}
	for (ImpMockNode *_Nonnull const mockNode in bottomRow) {
		ImpBTreeNode *_Nonnull const realLeafNode = [destTree allocateNewNodeOfKind:kBTLeafNode populate:^(void * _Nonnull bytes, NSUInteger length) {
			struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
			nodeDesc->height = 1;
		}];
		mockNode.nodeNumber = realLeafNode.nodeNumber;
	}

	//Convert the mock index nodes into real nodes.
	for (NSArray <ImpMockNode *> *_Nonnull const row in mockRows) {
		ImpBTreeNode *_Nullable lastRealNode = nil;
		for (ImpMockNode *_Nonnull const mockNode in row) {
			u_int32_t const nodeNumber = mockNode.nodeNumber;
			NSAssert(nodeNumber > 0, @"Can't copy a node with no node number. That would overwrite the header node, and that's bad!");
			ImpBTreeNode *_Nonnull const realNode = [destTree nodeAtIndex:nodeNumber];
			[mockNode writeIntoNode:realNode];
			[lastRealNode connectNextNode:realNode];
			lastRealNode = realNode;
		}
	}

	NSArray <ImpMockNode *> *_Nullable const topRow = mockRows.firstObject;
	NSAssert(topRow != nil, @"No top row? The converted tree is empty!");
	NSAssert(topRow.count == 1, @"Somehow the top row ended up containing more than one node; it should only contain the root node, but contains %@", topRow);
	ImpMockNode *_Nonnull const mockRootNode = topRow.firstObject;
	[destTree.headerNode reviseHeaderRecord:^(struct BTHeaderRec *_Nonnull const headerRecPtr) {
		S(headerRecPtr->rootNode, mockRootNode.nodeNumber);
		S(headerRecPtr->treeDepth, (u_int16_t)mockRows.count);
		S(headerRecPtr->firstLeafNode, bottomRow.firstObject.nodeNumber);
		S(headerRecPtr->lastLeafNode, bottomRow.lastObject.nodeNumber);
		S(headerRecPtr->leafRecords, (u_int32_t)keyValuePairs.count);
		u_int32_t const numPotentialNodes = (u_int32_t)destTree.numberOfPotentialNodes;
		u_int32_t const numFreeNodes = numPotentialNodes - numLiveNodes;
		S(headerRecPtr->totalNodes, numPotentialNodes);
		S(headerRecPtr->freeNodes, numFreeNodes);
	}];

	struct HFSPlusVolumeHeader *_Nonnull const vhPtr = _destinationVolume.mutableVolumeHeaderPointer;
	if (largestCNIDYet < UINT32_MAX) {
		S(vhPtr->nextCatalogID, largestCNIDYet + 1);
	} else {
		S(vhPtr->nextCatalogID, firstUnusedCNID);
		S(vhPtr->attributes, L(vhPtr->attributes) | kHFSCatalogNodeIDsReusedMask);
	}

	NSUInteger const numSrcLiveNodes = sourceTree.numberOfLiveNodes;
	NSUInteger const numDstLiveNodes = destTree.numberOfLiveNodes;
	ImpPrintf(@"HFS tree had %lu live nodes; HFS+ tree has %lu live nodes", numSrcLiveNodes, numDstLiveNodes);
}

///Map the number of an allocation block from the source volume (e.g., the start block of an extent) to the number of the corresponding block on the destination volume. By default, returns sourceBlock plus the source volume's first block number. You may need to override this method if the destination volume uses a different block size, or if you need to make exceptions for certain blocks (in extents that were relocated due to not fitting in the new volume).
- (u_int32_t) destinationBlockNumberForSourceBlockNumber:(u_int16_t) sourceBlock {
	__block u_int32_t firstBlockNumber = 0;
	[self.sourceVolume peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		firstBlockNumber = L(mdbPtr->drAlBlSt);
	}];
	return firstBlockNumber + sourceBlock;
}

//Note that the defragmenting converter overrides this method to do nothing. Until someone writes a non-defragmenting implementation, this code will remain untested. If that someone is you, don't be too surprised if there are bugs here or if this method needs other changes.
- (void) copyFromHFSExtentsOverflowFile:(ImpBTreeFile *_Nonnull const)sourceTree toHFSPlusExtentsOverflowFile:(ImpMutableBTreeFile *_Nonnull const)destTree {
	//Unlike the catalog file, we can convert records in this file 1:1 (as long as we don't change items' CNIDs, which would necessitate re-sorting).
	[sourceTree walkBreadthFirst:^bool(ImpBTreeNode *const  _Nonnull sourceNode) {
		[destTree allocateNewNodeOfKind:sourceNode.nodeType populate:^(void * _Nonnull destBytes, NSUInteger destLength) {
			[sourceNode peekAtDataRepresentation:^(NS_NOESCAPE NSData *const sourceData) {
				void const *_Nonnull const sourceBytes = sourceData.bytes;
				struct HFSExtentKey const *_Nonnull const sourceKeyPtr = sourceBytes;
				struct HFSPlusExtentKey *_Nonnull const destKeyPtr = destBytes;
				S(destKeyPtr->keyLength, sizeof(struct HFSPlusExtentKey) - sizeof(destKeyPtr->keyLength));
				S(destKeyPtr->forkType, L(sourceKeyPtr->forkType));
				S(destKeyPtr->pad, (u_int8_t)0);
				S(destKeyPtr->fileID, sourceKeyPtr->fileID);
				//TODO: This line right here is the part that doesn't make sense in a defragmenting converter that's going to invalidate all the block numbers.
				//TODO: Moreover, even a non-defragmenting converter would have to compute an offset to add to each of these, and account for any extents that have to be relocated if the converted volume runs out of space.
				S(destKeyPtr->startBlock, [self destinationBlockNumberForSourceBlockNumber:sourceKeyPtr->startBlock]);

				struct HFSExtentDescriptor const *_Nonnull const sourceExtentRec = sourceBytes + sizeof(struct HFSExtentKey);
				struct HFSPlusExtentDescriptor *_Nonnull const destExtentRec = destBytes + sizeof(struct HFSPlusExtentKey);
				for (u_int8_t i = 0; i < kHFSExtentDensity; ++i) {
					S(destExtentRec[i].startBlock, L(sourceExtentRec[i].startBlock));
					S(destExtentRec[i].blockCount, L(sourceExtentRec[i].blockCount));
				}
				S(destExtentRec[kHFSExtentDensity].startBlock, 0);
				S(destExtentRec[kHFSExtentDensity].blockCount, 0);
			}];
		}];

		return true;
	}];
}

#pragma mark Steps

- (bool) step0_preflight_error:(NSError *_Nullable *_Nullable const)outError {
	if ([self.sourceDevice isEqual:self.destinationDevice]) {
		NSError *_Nonnull const sameURLError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:@{ NSLocalizedDescriptionKey: @"Source and destination devices are the same" }];
		if (outError != NULL) *outError = sameURLError;
		return false;
	}

	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}
	int const writeFD = open(self.destinationDevice.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (writeFD < 0) {
		NSError *_Nonnull const cantOpenForWritingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open destination device for writing" }];
		if (outError != NULL) *outError = cantOpenForWritingError;
		return false;
	}

	ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD textEncoding:self.hfsTextEncoding];
	if (! [srcVol loadAndReturnError:outError])
		return false;
	self.sourceVolume = srcVol;

	u_int64_t sizeInBytes = 0;
	struct stat sb;
	int const statResult = fstat(readFD, &sb);
	if (statResult == 0) {
		off_t const sizeAccordingToStat = sb.st_size;
		sizeInBytes = sizeAccordingToStat > 0 ? sizeAccordingToStat : 0;
	}
	if (sizeInBytes == 0) {
		sizeInBytes = srcVol.totalSizeInBytes;
	}

	self.destinationVolume = [[ImpHFSPlusVolume alloc] initForWritingToFileDescriptor:writeFD volumeSizeInBytes:sizeInBytes];

	return true;
}

- (bool) step1_convertPreamble_error:(NSError *_Nullable *_Nullable const)outError {
	self.destinationVolume.bootBlocks = self.sourceVolume.bootBlocks;

	[self.sourceVolume peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		NSMutableData *_Nonnull const volumeHeaderData = [NSMutableData dataWithLength:sizeof(struct HFSPlusVolumeHeader)];
		struct HFSPlusVolumeHeader *_Nonnull const vhPtr = volumeHeaderData.mutableBytes;
		[self convertHFSVolumeHeader:mdbPtr toHFSPlusVolumeHeader:vhPtr];

		//We currently do this so the volume's _hasVolumeHeader gets set to true. Maybe that should have a setter method so we can use mutableVolumeHeaderPointer instead?
		self.destinationVolume.volumeHeader = volumeHeaderData;
	}];
	_numberOfSourceBlocksToCopy = self.sourceVolume.numberOfBlocksUsed;

	return [self.destinationVolume writeTemporaryPreamble:outError];
}

- (bool) step2_convertVolume_error:(NSError *_Nullable *_Nullable const)outError {
	NSAssert(false, @"Abstract class %@ does not implement convertVolume; subclass must implement it (also, you can't convert a volume with a non-subclassed %@)", [ImpHFSToHFSPlusConverter class], [ImpHFSToHFSPlusConverter class]);
	return false;
}

- (bool) step3_flushVolume_error:(NSError *_Nullable *_Nullable const)outError {
	bool const flushed = [self.destinationVolume flushVolumeStructures:outError];
	if (flushed) {
		[self reportSourceBlocksCopied:5]; //Two for the boot blocks, one for the volume header, one for the alternate volume header, and one for the reserved footer.
		ImpPrintf(@"Successfully wrote volume to %@", self.destinationDevice.absoluteURL.path);
	}
	return flushed;
}

@end

@implementation ImpCatalogItem

- (instancetype _Nonnull) initWithCatalogNodeID:(HFSCatalogNodeID const)cnid {
	if ((self = [super init])) {
		_cnid = cnid;
		_needsThreadRecord = true;
	}
	return self;
}

- (NSUInteger)hash {
	return self.cnid;
}
- (BOOL)isEqual:(id _Nonnull)other {
	@try {
		ImpCatalogItem *_Nonnull const fellowCatalogItemHopefully = other;
		return self.cnid == fellowCatalogItemHopefully.cnid;
	} @catch (NSException *_Nonnull const exception) {
		return false;
	}
}

@end

@implementation ImpCatalogKeyValuePair

- (instancetype _Nonnull)initWithKey:(NSData *_Nonnull const)keyData value:(NSData *_Nonnull const)valueData {
	NSParameterAssert(keyData.length >= kHFSPlusCatalogKeyMinimumLength);
	NSParameterAssert(keyData.length <= kHFSPlusCatalogKeyMaximumLength);
	if ((self = [super init])) {
		_key = keyData;
		_value = valueData;
	}
	return self;
}

- (NSString *_Nonnull) description {
	NSString *_Nonnull valueDescription = @"(empty)";
	if (self.value.length > sizeof(u_int16_t)) {
		u_int16_t const *_Nonnull const recordTypePtr = self.value.bytes;
		switch (L(*recordTypePtr)) {
			case kHFSFileRecord:
			case kHFSPlusFileRecord:
				valueDescription = @"file";
				break;

			case kHFSFolderRecord:
			case kHFSPlusFolderRecord:
				valueDescription = @"folder";
				break;

			case kHFSFileThreadRecord:
			case kHFSPlusFileThreadRecord:
				valueDescription = @"file thread";
				break;

			case kHFSFolderThreadRecord:
			case kHFSPlusFolderThreadRecord:
				valueDescription = @"folder thread";
				break;

			default:
				valueDescription = [NSString stringWithFormat:@"(unknown: 0x%04x)", L(*recordTypePtr)];
				break;
		}
	}
	return [NSString stringWithFormat:@"<%@ %p with key %@ and value type '%@'>",
		self.class, self,
		[ImpBTreeNode describeHFSPlusCatalogKeyWithData:self.key],
		valueDescription
	];
}

- (NSComparisonResult) caseInsensitiveCompare:(id)other {
	ImpCatalogKeyValuePair *_Nonnull const otherPair = other;
	return (NSComparisonResult)ImpBTreeCompareHFSPlusCatalogKeys(self.key.bytes, otherPair.key.bytes);
}

@end

@implementation ImpMockNode
{
	NSMutableArray <NSData *> *_Nonnull _allKeys;
	NSMutableArray <ImpCatalogKeyValuePair *> *_Nonnull _allPairs;
	u_int32_t _capacity;
}

- (instancetype) initWithCapacity:(u_int32_t const)maxNumBytes {
	if ((self = [super init])) {
		_capacity = maxNumBytes;
		_allKeys = [NSMutableArray arrayWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
		_allPairs = [NSMutableArray arrayWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
	}
	return self;
}

- (NSData *_Nullable) firstKey {
	return _allKeys.firstObject;
}

- (bool) canAppendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData {
	return (_capacity - _totalSizeOfAllRecords) >= (keyData.length + payloadData.length + sizeof(BTreeNodeOffset));
}

- (bool) appendKey:(NSData *_Nonnull const)keyData payload:(NSData *_Nonnull const)payloadData {
	if ([self canAppendKey:keyData payload:payloadData]) {
		[_allKeys addObject:keyData];
		ImpCatalogKeyValuePair *_Nonnull const kvp = [[ImpCatalogKeyValuePair alloc] initWithKey:keyData value:payloadData];
		[_allPairs addObject:kvp];
		_totalSizeOfAllRecords += (keyData.length + payloadData.length + sizeof(BTreeNodeOffset));
		return true;
	}
	return false;
}

- (void) writeIntoNode:(ImpBTreeNode *const)realNode {
	for (ImpCatalogKeyValuePair *_Nonnull const kvp in _allPairs) {
		bool const appended = [realNode appendRecordWithKey:kvp.key payload:kvp.value];
		NSAssert(appended, @"Could not append record to real node %@; it may be out of space (%u bytes remaining; key is %lu bytes and payload is %lu bytes)", realNode, realNode.numberOfBytesAvailable, kvp.key.length, kvp.value.length);
	}
}

- (NSArray <NSData *> *_Nonnull const) allKeys {
	return _allKeys;
}

@end

@implementation ImpMockIndexNode
{
	NSMutableDictionary <NSData *, ImpMockNode *> *_pointerRecords;
}

- (instancetype)initWithCapacity:(const u_int32_t)maxNumBytes {
	if ((self = [super initWithCapacity:maxNumBytes])) {
		_pointerRecords = [NSMutableDictionary dictionaryWithCapacity:maxNumBytes / kHFSCatalogKeyMinimumLength];
	}
	return self;
}

///Append a key to the node's list of pointer records, linked to the provided node.
- (bool) appendKey:(NSData *_Nonnull const)keyData fromNode:(ImpMockNode *_Nonnull const)descendantNode {
	NSMutableData *_Nonnull const blankPayloadData = [NSMutableData dataWithLength:sizeof(u_int32_t)];
	//We don't actually write descendantNode.nodeNumber into blankPayloadData because it hasn't been set yet, so we would just be overwriting the zero with a zero. Our overridden writeIntoNode: will get the real node number at the appropriate time. We're just using this blank NSData to represent the appropriate amount of space.

	if ([self appendKey:keyData payload:blankPayloadData]) {
		_pointerRecords[keyData] = descendantNode;
		return true;
	}
	return false;
}

///Add records to a real index node to match the contents of this mock node.
- (void) writeIntoNode:(ImpBTreeNode *_Nonnull const)realNode {
	NSParameterAssert([realNode isKindOfClass:[ImpBTreeIndexNode class]]);
	ImpBTreeIndexNode *_Nonnull const realIndexNode = (ImpBTreeIndexNode *_Nonnull const)realNode;
	for (NSData *_Nonnull const key in self.allKeys) {
		ImpMockNode *_Nonnull const obj = _pointerRecords[key];
		NSMutableData *_Nonnull const payloadData = [NSMutableData dataWithLength:sizeof(u_int32_t)];
		u_int32_t *_Nonnull const pointerRecordPtr = payloadData.mutableBytes;
		S(*pointerRecordPtr, obj.nodeNumber);

		NSString *_Nonnull const filename = [ImpBTreeNode nodeNameFromHFSPlusCatalogKey:key];
		ImpPrintf(@"Node #%u: Wrote index record for file “%@”: %u -(swap)-> %u", realIndexNode.nodeNumber, filename, obj.nodeNumber, *pointerRecordPtr);

		[realIndexNode appendRecordWithKey:key payload:payloadData];
	}
}

@end
