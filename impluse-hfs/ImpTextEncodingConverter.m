//
//  ImpTextEncodingConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpTextEncodingConverter.h"

#import "ImpPrintf.h"
#import "ImpErrorUtilities.h"

@implementation ImpTextEncodingConverter
{
	TextEncoding _hfsTextEncoding, _hfsPlusTextEncoding;
	TextToUnicodeInfo _ttui;
}

+ (instancetype _Nullable) converterWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding {
	return [[self alloc] initWithHFSTextEncoding:hfsTextEncoding];
}
///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
- (instancetype _Nullable) initWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding {
	if ((self = [super init])) {
		_hfsTextEncoding = hfsTextEncoding;
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

- (instancetype) init {
	NSAssert(false, @"You must use initWithHFSTextEncoding: to properly initialize an ImpTextEncodingConverter.");
	return nil;
}

- (void)dealloc {
	DisposeTextToUnicodeInfo(&_ttui);
}

- (ByteCount) estimateSizeOfHFSUniStr255NeededForPascalString:(ConstStr31Param _Nonnull const)pascalString {
	//The length in MacRoman characters may include accented characters that HFS+ decomposition will decompose to a base character and a combining character, so we actually need to double the length *in characters*.
	ByteCount outputPayloadSizeInBytes = (2 * *pascalString) * sizeof(UniChar);
	//TECConvertText documentation: “Always allocate a buffer at least 32 bytes long.”
	if (outputPayloadSizeInBytes < 32) {
		outputPayloadSizeInBytes = 32;
	}
	ByteCount const outputBufferSizeInBytes = outputPayloadSizeInBytes + 1 * sizeof(UniChar);
	return outputBufferSizeInBytes;
}
- (bool) convertPascalString:(ConstStr31Param _Nonnull const)pascalString intoHFSUniStr255:(HFSUniStr255 *_Nonnull const)outUnicode bufferSize:(ByteCount)outputBufferSizeInBytes {
	UniChar *_Nonnull const outputBuf = (UniChar *)outUnicode;

	ByteCount const outputPayloadSizeInBytes = outputBufferSizeInBytes - 1 * sizeof(UniChar);
	ByteCount actualOutputLengthInBytes = 0;
	OSStatus err = ConvertFromPStringToUnicode(_ttui, pascalString, outputPayloadSizeInBytes, &actualOutputLengthInBytes, outputBuf + 1);

	if (err == paramErr) {
		//Set a breakpoint here to try to step into ConvertFromPStringToUnicode.
		NSLog(@"Unicode conversion failure!");
		err = ConvertFromPStringToUnicode(_ttui, pascalString, outputPayloadSizeInBytes, &actualOutputLengthInBytes, outputBuf + 1);
	}

	if (err == noErr) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
		//Swap all the bytes in the output data.
		swab(outputBuf + 1, outputBuf + 1, actualOutputLengthInBytes);
#endif
	} else {
		NSMutableData *_Nonnull const cStringData = [NSMutableData dataWithLength:pascalString[0]];
		char *_Nonnull const cStringBytes = cStringData.mutableBytes;
		memcpy(cStringBytes, pascalString + 1, *pascalString);
		ImpPrintf(@"Failed to convert filename '%s' (length %u) to Unicode: error %d/%s", (char const *)cStringBytes, (unsigned)*pascalString, err, ImpExplainOSStatus(err));
		if (err == kTECOutputBufferFullStatus) {
			ImpPrintf(@"Output buffer full: %lu vs. buffer size %lu", (unsigned long)actualOutputLengthInBytes, outputPayloadSizeInBytes);
		}
		return false;
	}

	S(outputBuf[0], (u_int16_t)(actualOutputLengthInBytes / sizeof(UniChar)));
	return true;
}
- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param)pascalString {
	ByteCount const outputBufferSizeInBytes = [self estimateSizeOfHFSUniStr255NeededForPascalString:pascalString];
	NSMutableData *_Nonnull const unicodeData = [NSMutableData dataWithLength:outputBufferSizeInBytes];

	if (*pascalString == 0) {
		//TEC doesn't like converting empty strings, so just return our empty HFSUniStr255 without calling TEC.
		return unicodeData;
	}

	UniChar *_Nonnull const outputBuf = unicodeData.mutableBytes;
	bool const converted = [self convertPascalString:pascalString intoHFSUniStr255:(HFSUniStr255 *)outputBuf bufferSize:outputBufferSizeInBytes];

	return converted ? unicodeData : nil;
}
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param)pascalString {
	NSData *_Nonnull const unicodeData = [self hfsUniStr255ForPascalString:pascalString];
	/* This does not seem to work.
	 hfsUniStr255ForPascalString: needs to return UTF-16 BE so we can write it out to HFS+. But if we call CFStringCreateWithPascalString, it seems to always take the host-least-significant byte and treat it as a *byte count*. That basically means this always returns an empty string. If the length is unswapped, it returns the first half of the string.
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, unicodeData.bytes, kCFStringEncodingUTF16BE);
	 */
	CFIndex const numCharacters = L(*(UniChar *)unicodeData.bytes);
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, unicodeData.bytes + sizeof(UniChar), numCharacters * sizeof(UniChar), kCFStringEncodingUTF16BE, /*isExternalRep*/ false);
	return unicodeString;
}

@end
