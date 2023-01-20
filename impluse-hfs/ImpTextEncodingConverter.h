//
//  ImpTextEncodingConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import <Foundation/Foundation.h>

@interface ImpTextEncodingConverter : NSObject

///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
+ (instancetype _Nullable) converterWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding;
///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
- (instancetype _Nullable) initWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding;

///Obtain an estimate of how many bytes might be needed to hold the Unicode conversion of this string, including 2 bytes for the length.
- (ByteCount) estimateSizeOfHFSUniStr255NeededForPascalString:(ConstStr31Param _Nonnull const)pascalString;
///Returns true if the characters were successfully converted; returns false if some characters could not be converted or there wasn't enough space.
- (bool) convertPascalString:(ConstStr31Param _Nonnull const)pascalString intoHFSUniStr255:(HFSUniStr255 *_Nonnull const)outUnicode bufferSize:(ByteCount)outputBufferSizeInBytes;

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull const)pascalString;
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull const)pascalString;

- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param _Nonnull const)unicodeName;

@end
