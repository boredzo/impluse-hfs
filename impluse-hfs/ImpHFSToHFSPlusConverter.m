//
//  ImpHFSToHFSPlusConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSToHFSPlusConverter.h"

#import <hfs/hfs_format.h>
#import <CoreServices/CoreServices.h>

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpErrorUtilities.h"
#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpExtentSeries.h"

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

- (void) deliverProgressUpdate:(double)progress
	operationDescription:(NSString *_Nonnull)operationDescription
{
	if (self.conversionProgressUpdateBlock != nil) {
		self.conversionProgressUpdateBlock(progress, operationDescription);
	}
}

///Note that this does not strictly give a _logical_ file size (as in, length in bytes) because that can't be derived from a block count. This is an upper bound on the logical file size. Still, if we don't have the logical file size and computing it would be non-trivial (e.g., require computing the total size of all nodes in a B*-tree), this is the next best thing and hopefully not too problematic.
- (u_int64_t) estimateFileSizeFromExtentSeries:(ImpExtentSeries *_Nonnull const)series {
	__block u_int64_t total = 0;
	[series forEachExtent:^(struct HFSPlusExtentDescriptor const *_Nonnull const extDesc) {
		total += L(extDesc->blockCount) * kISOStandardBlockSize;
	}];

	return total;
}

- (void) convertHFSVolumeHeader:(struct HFSMasterDirectoryBlock const *_Nonnull const)mdbPtr toHFSPlusVolumeHeader:(struct HFSPlusVolumeHeader *_Nonnull const)vhPtr
{
	struct HFSPlusVolumeHeader vh = {
		.signature = kHFSPlusSigWord,
		.version = kHFSPlusVersion,
		.attributes = mdbPtr->drAtrb,
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
		.encodingsBitmap = 0, //TODO: Compute this? Guess it?
		.finderInfo = { 0 }, //mdbPtr->drFndrInfo,
	};
	//TODO: Can we get away with just copying the volume's Finder info verbatim? The size is the same, but are all the fields the same? (IM:F doesn't elaborate on the on-disk volume Finder info format, unfortunately.)
	memcpy(&(vh.finderInfo), &(mdbPtr->drFndrInfo), 8 * sizeof(u_int32_t));

	//Translate the VBM into the allocation file, and the extents and catalog files into their HFS+ counterparts.
	//The VBM is implied by IM:F to be necessarily contiguous (only the catalog and extents overflow files are expressly not), and is guaranteed to always be at block #3 in HFS. On HFS+, the VBM isn't necessarily contiguous.
	//The VBM (at least in HFS+) indicates the allocation state of the entire volume, so its length in bits is the number of allocation blocks for the whole volume. Divide by eight to get bytes, and then by the allocation block size to get blocks.
	u_int16_t const allocationFileSizeInBytes = L(mdbPtr->drNmAlBlks) / 8; //drNmAlBlks is u_int16_t; we don't need to go any bigger than that for this computation.
	S(vh.allocationFile.totalBlocks, allocationFileSizeInBytes / L(vh.blockSize));
	vh.allocationFile.clumpSize = mdbPtr->drClpSiz;
	S(vh.allocationFile.logicalSize, L(vh.allocationFile.totalBlocks) * kISOStandardBlockSize);
	vh.allocationFile.extents[0].startBlock = mdbPtr->drVBMSt;
	vh.allocationFile.extents[0].blockCount = vh.allocationFile.totalBlocks;

	vh.catalogFile.totalBlocks = mdbPtr->drCTFlSize;
	vh.catalogFile.clumpSize = mdbPtr->drCTClpSiz;
	ImpExtentSeries *_Nonnull const catExtentSeries = [ImpExtentSeries new];
	[catExtentSeries appendHFSExtentRecord:mdbPtr->drCTExtRec];
	[catExtentSeries getHFSPlusExtentRecordAtIndex:0 buffer:vh.catalogFile.extents];
	vh.catalogFile.logicalSize = [self estimateFileSizeFromExtentSeries:catExtentSeries];

	vh.extentsFile.totalBlocks = mdbPtr->drXTFlSize;
	vh.extentsFile.clumpSize = mdbPtr->drXTClpSiz;
	ImpExtentSeries *_Nonnull const extExtentSeries = [ImpExtentSeries new];
	[extExtentSeries appendHFSExtentRecord:mdbPtr->drXTExtRec];
	[catExtentSeries getHFSPlusExtentRecordAtIndex:0 buffer:vh.extentsFile.extents];
	vh.extentsFile.logicalSize = [self estimateFileSizeFromExtentSeries:extExtentSeries];

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

- (bool)performConversionOrReturnError:(NSError *_Nullable *_Nonnull) outError {
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

	[self deliverProgressUpdate:0.0 operationDescription:@"Reading HFS volume structures"];

	ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD textEncoding:self.hfsTextEncoding];
	if (! [srcVol loadAndReturnError:outError])
		return false;

	struct HFSMasterDirectoryBlock mdb;
}

@end
