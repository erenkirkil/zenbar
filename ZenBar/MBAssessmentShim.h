#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL zenbar_assessmentModeAvailable(void);
NSString *zenbar_describeAssessmentClasses(void);

id _Nullable zenbar_makeConfiguration(NSArray<NSNumber *> *allowedSystemItems,
                                     NSArray<NSString *> *allowedBundleIDs);

id _Nullable zenbar_activateAssertion(id configuration,
                                     void (^completion)(NSError * _Nullable error));

void zenbar_invalidateAssertion(id _Nullable assertion);
void zenbar_logMessage(NSString *message);

NS_ASSUME_NONNULL_END
