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
#import "NSData+ImpMultiplication.h"
#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpVolumeProbe.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpMutableBTreeFile.h"
#import "ImpExtentSeries.h"
#import "ImpTextEncodingConverter.h"
#import "ImpCatalogBuilder.h"

NSString *_Nonnull const ImpRescuedDataFileName = @"!!! Data impluse recovered from orphaned blocks";

@implementation ImpHFSToHFSPlusConverter
{
	NSData *_placeholderForkData;
	TextEncoding _hfsTextEncoding, _hfsPlusTextEncoding;
	TextToUnicodeInfo _ttui;
	int _readFD, _writeFD;
	bool _hasReportedPostVolumeLength;
}

+ (NSData *_Nonnull const) placeholderForkData {
	static NSData *_Nullable placeholderForkData = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		static char bytes[513] =
			"This block is in a file that was copied from an HFS volume using impluse. impluse was told to not copy fork data, so it wrote this message instead. You should see it repeated throughout each and every occupied block in every copied file.\x0d"
			"\x0d"
			"Any files not containing this message were not copied, but were created directly on this volume after conversion.\x0d"
			"\x0d"
			"Resource forks will not work. Applications will not launch, custom icons will be missing, and the desktop database may need to be rebuilt.\x0d"
			"\x0d"
			"Message repeats\xc9\x0d" /*Note: \xc9 is the ellipsis character, …, in MacRoman*/
			"\x0d";
		size_t const stringLength = strlen(bytes);
		NSAssert(stringLength == 512, @"Incorrect placeholder text length: %zu", stringLength);
		placeholderForkData = [NSData dataWithBytesNoCopy:bytes length:stringLength freeWhenDone:false];
	});
	return placeholderForkData;
}

- (NSData *_Nonnull const) placeholderForkData {
	if (_placeholderForkData == nil) {
		NSData *_Nonnull const oneBlockPlaceholder = [[self class] placeholderForkData];
		NSUInteger const srcBlockSize = self.sourceVolume.numberOfBytesPerBlock;
		NSAssert(srcBlockSize > 0, @"Can't build placeholder fork data until source volume's block size is known");
		NSUInteger const multiplier = srcBlockSize / oneBlockPlaceholder.length;
		_placeholderForkData = [oneBlockPlaceholder times_Imp:multiplier];
		NSLog(@"Placeholder size: %lu bytes", _placeholderForkData.length);
	}
	return _placeholderForkData;
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
- (void) reportSourceBlocksWillBeCopied:(NSUInteger const)thisManyMore {
	if (thisManyMore > UINT32_MAX) {
		NSLog(@"Strange number of pending blocks reported: %lu", thisManyMore);
	}
	self.numberOfSourceBlocksToCopy = self.numberOfSourceBlocksToCopy + thisManyMore;
}
- (void) reportSourceBlocksWillNotBeCopied:(NSUInteger const)thisManyFewer {
	self.numberOfSourceBlocksToCopy = self.numberOfSourceBlocksToCopy - thisManyFewer;
}
- (void) reportSourceExtentRecordCopied:(struct HFSExtentDescriptor const *_Nonnull const)extRecPtr {
	[self reportSourceBlocksCopied:ImpNumberOfBlocksInHFSExtentRecord(extRecPtr)];
}
- (void) reportSourceExtentRecordWillNotBeCopied:(struct HFSExtentDescriptor const *_Nonnull const)extRecPtr {
	[self reportSourceBlocksWillNotBeCopied:ImpNumberOfBlocksInHFSExtentRecord(extRecPtr)];
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
#if LOG_NUMBER_OF_BLOCKS_REMAINING
	static NSNumberFormatter *_Nullable numberFormatter = nil;
	if (numberFormatter == nil) {
		numberFormatter = [NSNumberFormatter new];
		numberFormatter.format = @",##0";
	}
	ImpPrintf(@"(Blocks copied: %@ of %@; %@ remain)", [numberFormatter stringFromNumber:@(self.numberOfSourceBlocksCopied)], [numberFormatter stringFromNumber:@(self.numberOfSourceBlocksToCopy)], [numberFormatter stringFromNumber:@(self.numberOfSourceBlocksToCopy - self.numberOfSourceBlocksCopied)]);
#endif
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
	//The VBM is implied by IM:F to be necessarily contiguous (only the catalog and extents overflow files are expressly not), and is guaranteed to always be at block #3 in HFS. On HFS+, the VBM isn't necessarily contiguous nor does it have to start at block #3.
	vh.allocationFile.clumpSize = mdbPtr->drClpSiz;
	//We intentionally don't use the HFS volume's drVBMSt. Generally, the block allocator will arrive at the same answer, placing the allocations file in the first available a-blocks. If that answer differs, it's probably because drVBMSt was something strange that we don't care about replicating.
	vh.allocationFile.extents[0].startBlock = vh.allocationFile.extents[0].blockCount = vh.allocationFile.totalBlocks = 0;
	vh.allocationFile.logicalSize = 0;

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

	struct ExtendedFileInfo const *_Nonnull const extFinderInfo = (struct ExtendedFileInfo const *)&(srcFilePtr->finderInfo);
	UInt16 const extFinderFlags = L(extFinderInfo->extendedFinderFlags);
	TextEncoding const embeddedScriptCode = [ImpTextEncodingConverter textEncodingFromExtendedFinderFlags:extFinderFlags defaultEncoding:self.hfsTextEncoding];

	S(destFilePtr->textEncoding, embeddedScriptCode);
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

- (u_int16_t) destinationCatalogNodeSize {
	return [ImpBTreeFile nodeSizeForVersion:ImpBTreeVersionHFSPlusCatalog];
}

- (ImpMutableBTreeFile *_Nonnull) convertHFSCatalogFile:(ImpBTreeFile *_Nonnull const)sourceTree {
	NSUInteger const numItems = self.sourceVolume.numberOfFiles + self.sourceVolume.numberOfFolders;
	ImpCatalogBuilder *_Nonnull const catBuilder = [[ImpCatalogBuilder alloc] initWithBTreeVersion:ImpBTreeVersionHFSPlusCatalog
		bytesPerNode:self.destinationCatalogNodeSize
		expectedNumberOfItems:numItems];
	catBuilder.treeDepthHint = sourceTree.headerNode.treeDepth;
//	ImpTextEncodingConverter *_Nonnull const tec = self.sourceVolume.textEncodingConverter;

	//Gather our list of all items, converting file, folder, and thread records as we go and keeping each item's file/folder record and thread record (if it has one) together.
	[sourceTree walkLeafNodes:^bool(ImpBTreeNode *const  _Nonnull node) {
		[node forEachHFSCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRecPtr) {
			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)fileRecPtr length:sizeof(struct HFSCatalogFile) freeWhenDone:false];
			NSMutableData *_Nonnull const destKeyData = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			NSMutableData *_Nonnull const destRecData = [self convertHFSCatalogFileRecordToHFSPlus:sourceRecData];
			ImpCatalogItem *_Nonnull const item = [catBuilder addKey:destKeyData fileRecord:destRecData];
			item.sourceKey = sourceKeyData;
			item.sourceRecord = sourceRecData;

		} folder:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRecPtr) {
			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)folderRecPtr length:sizeof(struct HFSCatalogFolder) freeWhenDone:false];
			NSMutableData *_Nonnull const destKeyData = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			NSMutableData *_Nonnull const destRecData = [self convertHFSCatalogFolderRecordToHFSPlus:sourceRecData];
			ImpCatalogItem *_Nonnull const item = [catBuilder addKey:destKeyData folderRecord:destRecData];
			item.sourceKey = sourceKeyData;
			item.sourceRecord = sourceRecData;
		} thread:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRecPtr) {
			NSData *_Nonnull const sourceKeyData = [NSData dataWithBytesNoCopy:(void *)catalogKeyPtr length:sizeof(struct HFSCatalogKey) freeWhenDone:false];
			NSData *_Nonnull const sourceRecData = [NSData dataWithBytesNoCopy:(void *)threadRecPtr length:sizeof(struct HFSCatalogThread) freeWhenDone:false];
			NSMutableData *_Nonnull const destKeyData = [self convertHFSCatalogKeyToHFSPlus:sourceKeyData];
			NSMutableData *_Nonnull const destRecData = [self convertHFSCatalogThreadRecordToHFSPlus:sourceRecData];
			ImpCatalogItem *_Nonnull const item = [catBuilder addKey:destKeyData threadRecord:destRecData];
			item.sourceThreadKey = sourceKeyData;
			item.sourceThreadRecord = sourceRecData;
		}];
		return true;
	}];

	if ([self.sourceVolume numberOfBlocksThatAreAllocatedButAreNotReferencedInTheBTrees] > 0) {
		enum { HexEditCreatorCode = 'hDmp' };
		[catBuilder createFileInParent:kHFSRootFolderID
			name:ImpRescuedDataFileName
			type:'????'
			creator:HexEditCreatorCode
			finderFlags:kHasBeenInited | kNameLocked | kHasNoINITs];
	}

	ImpMutableBTreeFile *_Nonnull const destTree = [[ImpMutableBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusCatalog
		bytesPerNode:self.destinationCatalogNodeSize
		nodeCount:catBuilder.totalNodeCount
		convertTree:sourceTree];

	[catBuilder populateTree:destTree];

	struct HFSPlusVolumeHeader *_Nonnull const vhPtr = _destinationVolume.mutableVolumeHeaderPointer;
	S(vhPtr->nextCatalogID, catBuilder.nextCatalogNodeID);
	if (catBuilder.hasReusedCatalogNodeIDs) {
		S(vhPtr->attributes, L(vhPtr->attributes) | kHFSCatalogNodeIDsReusedMask);
	} else {
		S(vhPtr->attributes, L(vhPtr->attributes) & ~kHFSCatalogNodeIDsReusedMask);
	}

//	NSUInteger const numSrcLiveNodes = sourceTree.numberOfLiveNodes;
//	NSUInteger const numSrcPotentialNodes = sourceTree.numberOfPotentialNodes;
	NSUInteger const numDstLiveNodes = destTree.numberOfLiveNodes;
	NSUInteger const numDstPotentialNodes = destTree.numberOfPotentialNodes;
//	ImpPrintf(@"HFS tree had %lu live nodes out of %lu; HFS+ tree has %lu live nodes out of %lu", numSrcLiveNodes, numSrcPotentialNodes, numDstLiveNodes, numDstPotentialNodes);
	NSAssert(numDstLiveNodes <= numDstPotentialNodes, @"Conversion failure: Produced more catalog nodes than the catalog file was preallocated for (please file a bug, include this message, and if possible and legal attach the disk image you were trying to convert)");

	return destTree;
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

	_readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (_readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}
	_writeFD = open(self.destinationDevice.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (_writeFD < 0) {
		NSError *_Nonnull const cantOpenForWritingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open destination device for writing" }];
		if (outError != NULL) *outError = cantOpenForWritingError;
		return false;
	}

	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:_readFD];
	__block bool haveFoundHFSVolume = false;
	__block bool loadedSuccessfully = false;
	__block NSError *_Nullable volumeLoadError = nil;
	[probe findVolumes:^(u_int64_t const startOffsetInBytes, u_int64_t const lengthInBytes, Class _Nullable const volumeClass) {
		if (! haveFoundHFSVolume) {
			if (volumeClass != Nil && volumeClass != [ImpHFSVolume class]) {
				//We have an identified volume class, but it isn't HFS. Most likely, this is already HFS+. Skip.
				return;
			}

			ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:self->_readFD
				startOffsetInBytes:startOffsetInBytes
				lengthInBytes:lengthInBytes
				textEncoding:self.hfsTextEncoding];
			loadedSuccessfully = [srcVol loadAndReturnError:&volumeLoadError];
			if (loadedSuccessfully) {
				self.sourceVolume = srcVol;

				u_int64_t const totalSizeOfSourceBlocks = self.sourceVolume.numberOfBytesPerBlock * self.sourceVolume.numberOfBlocksTotal;
				u_int64_t const destinationLengthInBytes = MAX(lengthInBytes, totalSizeOfSourceBlocks);
				self.destinationVolume = [[ImpHFSPlusVolume alloc] initForWritingToFileDescriptor:self->_writeFD
					startAtOffset:startOffsetInBytes
					expectedLengthInBytes:destinationLengthInBytes];

				haveFoundHFSVolume = true;
			}
		}
	}];
	if (! loadedSuccessfully) {
		if (outError) {
			*outError = volumeLoadError;
		}
	}

	if (haveFoundHFSVolume) {
		//Strictly speaking, the data before and after the volume doesn't need to be a multiple of the block size.
		//But the denominator of our progress calculation is in source allocation blocks, so using ISO standard blocks for surrounding data could exaggerate its proportion of what remains to be copied.
		u_int64_t const volumeStartOffset = self.sourceVolume.startOffsetInBytes;
		u_int64_t const blockSize = self.sourceVolume.numberOfBytesPerBlock;
		[self reportSourceBlocksWillBeCopied:ImpCeilingDivide(volumeStartOffset, blockSize)];

		struct stat sb;
		int const statResult = fstat(_readFD, &sb);
		if (statResult == 0 && sb.st_size > 0) {
			u_int64_t const overallSourceLength = sb.st_size;
			u_int64_t const volumeLength = self.sourceVolume.lengthInBytes;
			u_int64_t const volumeEndOffset = (volumeStartOffset + volumeLength);
			[self reportSourceBlocksWillBeCopied:ImpCeilingDivide((overallSourceLength - volumeEndOffset), blockSize)];
			_hasReportedPostVolumeLength = true;
		}
	}

	return haveFoundHFSVolume;
}

- (bool) step1_convertPreamble_error:(NSError *_Nullable *_Nullable const)outError {
	self.destinationVolume.bootBlocks = self.sourceVolume.bootBlocks;
	self.destinationVolume.lastBlock = self.sourceVolume.lastBlock;
//	ImpPrintf(@"Set destination volume's last block to %@", self.sourceVolume.lastBlock);

	[self.sourceVolume peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		NSMutableData *_Nonnull const volumeHeaderData = [NSMutableData dataWithLength:sizeof(struct HFSPlusVolumeHeader)];
		struct HFSPlusVolumeHeader *_Nonnull const vhPtr = volumeHeaderData.mutableBytes;
		[self convertHFSVolumeHeader:mdbPtr toHFSPlusVolumeHeader:vhPtr];

		//We currently do this so the volume's _hasVolumeHeader gets set to true. Maybe that should have a setter method so we can use mutableVolumeHeaderPointer instead?
		self.destinationVolume.volumeHeader = volumeHeaderData;
	}];
	[self reportSourceBlocksWillBeCopied:self.sourceVolume.numberOfBlocksUsed];

	return [self.destinationVolume writeTemporaryPreamble:outError];
}

- (bool) step2_convertVolume_error:(NSError *_Nullable *_Nullable const)outError {
	NSAssert(false, @"Abstract class %@ does not implement convertVolume; subclass must implement it (also, you can't convert a volume with a non-subclassed %@)", [ImpHFSToHFSPlusConverter class], [ImpHFSToHFSPlusConverter class]);
	return false;
}

///Copy the partition map (if any) and any other partitions before the volume.
- (bool) copyBytesBeforeVolume_error:(NSError *_Nullable *_Nullable const)outError {
	lseek(_readFD, 0, SEEK_SET);
	lseek(_writeFD, 0, SEEK_SET);

	ImpHFSVolume *_Nonnull const srcVol = self.sourceVolume;
	u_int64_t const blockSize = srcVol.numberOfBytesPerBlock;
	NSMutableData *_Nonnull const bufferData = [NSMutableData dataWithLength:blockSize];
	void *_Nonnull const buf = bufferData.mutableBytes;

	u_int64_t const numBytesBeforeVolume = srcVol.startOffsetInBytes;
	u_int64_t const numBlocksBeforeVolume = ImpCeilingDivide(numBytesBeforeVolume, blockSize);
	for (u_int64_t i = 0; i < numBlocksBeforeVolume; ++i) {
		ssize_t amtRead = read(_readFD, buf, blockSize);
		if (amtRead < 0) {
			NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Failure to read data prior to volume", @"Converter error") }];
			if (outError != NULL) {
				*outError = readError;
			}
			return false;
		}

		ssize_t amtWritten = write(_writeFD, buf, blockSize);
		if (amtWritten < 0) {
			NSError *_Nonnull const writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Failure to write data prior to volume", @"Converter error") }];
			if (outError != NULL) {
				*outError = writeError;
			}
			return false;
		}

		[self reportSourceBlocksCopied:1];
	}

	return true;
}
///Copy any other partitions after the volume.
- (bool) copyBytesAfterVolume_error:(NSError *_Nullable *_Nullable const)outError {
	ImpHFSVolume *_Nonnull const srcVol = self.sourceVolume;
	u_int64_t const numBytesBeforeEndOfVolume = srcVol.startOffsetInBytes + srcVol.lengthInBytes;
	lseek(_readFD, numBytesBeforeEndOfVolume, SEEK_SET);
	lseek(_writeFD, numBytesBeforeEndOfVolume, SEEK_SET);

	u_int64_t const blockSize = srcVol.numberOfBytesPerBlock;

	NSMutableData *_Nonnull const bufferData = [NSMutableData dataWithLength:blockSize];
	void *_Nonnull const buf = bufferData.mutableBytes;

	ssize_t amtRead = 0;
	while ((amtRead = read(_readFD, buf, blockSize)) > 0) {
		ssize_t amtWritten = write(_writeFD, buf, blockSize);
		if (amtWritten < 0) {
			NSError *_Nonnull const writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Failure to write data following volume", @"Converter error") }];
			if (outError != NULL) {
				*outError = writeError;
			}
			return false;
		}

		//If we haven't previously reported the number of these blocks to be copied, don't worry about reporting them copied.
		if (_hasReportedPostVolumeLength) {
			[self reportSourceBlocksCopied:1];
		}
	}
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Failure to read data following volume", @"Converter error") }];
		if (outError != NULL) {
			*outError = readError;
		}
		return false;
	}

	return true;
}
- (bool) step3_flushVolume_error:(NSError *_Nullable *_Nullable const)outError {
	if (! [self copyBytesBeforeVolume_error:outError]) {
		return false;
	}
	if (! [self copyBytesAfterVolume_error:outError]) {
		return false;
	}

	bool const flushed = [self.destinationVolume flushVolumeStructures:outError];
	if (flushed) {
		[self deliverProgressUpdateWithOperationDescription:NSLocalizedString(@"Successfully wrote volume", @"Conversion progress message")];
	}

	//Attempt to set the destination file (if it's a regular file) as read-only so it can't be accidentally mounted read/write.
	NSNumber *_Nullable isRegularFileValue = nil;
	bool const canCheckIsRegularFile = [self.destinationDevice getResourceValue:&isRegularFileValue forKey:NSURLIsRegularFileKey error:NULL];
	if (canCheckIsRegularFile && isRegularFileValue != nil && isRegularFileValue.boolValue) {
		chmod(self.destinationDevice.path.fileSystemRepresentation, 0444);
	}

	return flushed;
}

@end
