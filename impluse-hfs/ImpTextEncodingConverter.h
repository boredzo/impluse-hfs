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

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull const)pascalString;
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull const)pascalString;

@end
