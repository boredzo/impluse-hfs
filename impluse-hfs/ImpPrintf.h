//
//  ImpPrintf.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-01.
//

#import <Foundation/Foundation.h>

///Call this from GUI applications where spamming the console isn't necessarily helpful.
bool ImpSetPrintfMuffle(bool muffled);

int ImpPrintf(NSString *_Nonnull const fmt, ...) NS_FORMAT_FUNCTION(1,2) NS_NO_TAIL_CALL;
