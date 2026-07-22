public with sharing class SlackSubmitInvoker {
    public class SubmitRequest {
        @InvocableVariable
        public String channelId;

        @InvocableVariable
        public String opportunityId;
    }

    @InvocableMethod(label='Post Slack Approval Button' description='Send Slack approval button to a channel for an Opportunity')
    public static void postSubmitButton(List<SubmitRequest> requests) {
        for (SubmitRequest req : requests) {
            if (req.channelId != null && req.opportunityId != null) {
                postSubmitButtonAsync(req.channelId, req.opportunityId);
            }
        }
    }

    @future(callout=true)
    public static void postSubmitButtonAsync(String channelId, String opportunityId) {
        SlackApiService.postSubmitButton(channelId, opportunityId);
    }
}