//
//  ImpErrorUtilities.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpErrorUtilities.h"

char const *_Nullable const ImpExplainOSStatus(OSStatus const err) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return GetMacOSStatusCommentString(err);
#pragma clang diagnostic pop
}
