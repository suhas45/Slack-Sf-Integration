public without sharing class SlackCalloutService {

    @future(callout=true)
    public static void postToChannelAsync(String channelId, String text) {
        SlackApiService.postToChannel(channelId, text);
    }

    @future(callout=true)
    public static void postDMAsync(String slackUserId, String text, String accountId) {
        SlackApiService.postDM(slackUserId, text, accountId);
    }
}