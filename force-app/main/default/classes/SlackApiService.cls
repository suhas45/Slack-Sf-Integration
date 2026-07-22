public without sharing class SlackApiService {

    private static String getBotToken() {
        Slack_config__mdt cfg = [SELECT Bot_Token__c FROM Slack_config__mdt LIMIT 1];
        return cfg.Bot_Token__c;
    }

    private static HttpResponse callSlack(String endpoint, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://slack.com/api/' + endpoint);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getBotToken());
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setBody(JSON.serialize(body));
        Http http = new Http();
        return http.send(req);
    }

    public static void postSubmitButton(String channelId, String opportunityId) {
        Map<String, Object> block = new Map<String, Object>{
            'type' => 'section',
            'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Opportunity Approval*\nClick below to submit this opportunity for approval.' }
        };
        Map<String, Object> actions = new Map<String, Object>{
            'type' => 'actions',
            'elements' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'button',
                    'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Submit for Approval' },
                    'style' => 'primary',
                    'action_id' => 'submit_approval',
                    'value' => opportunityId
                }
            }
        };
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'text' => 'Opportunity Approval',
            'blocks' => new List<Object>{ block, actions }
        };
        HttpResponse res = callSlack('chat.postMessage', body);
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String ts = (String) result.get('ts');
        if (ts != null) {
            pinMessage(channelId, ts);
        }
    }

    private static void pinMessage(String channelId, String ts) {
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'timestamp' => ts
        };
        callSlack('pins.add', body);
    }

    public static void openApproverSelectModal(String triggerId, String opportunityId) {
        Map<String, Object> view = new Map<String, Object>{
            'type' => 'modal',
            'callback_id' => 'approver_select_modal',
            'private_metadata' => opportunityId,
            'title' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Select Approver' },
            'submit' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Send' },
            'close' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Cancel' },
            'blocks' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'input',
                    'block_id' => 'approver_block',
                    'element' => new Map<String, Object>{
                        'type' => 'users_select',
                        'action_id' => 'approver_user'
                    },
                    'label' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Approver' }
                }
            }
        };
        Map<String, Object> body = new Map<String, Object>{
            'trigger_id' => triggerId,
            'view' => view
        };
        callSlack('views.open', body);
    }

    public static String getUserEmail(String slackUserId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://slack.com/api/users.info?user=' + slackUserId);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + getBotToken());
        Http http = new Http();
        HttpResponse res = http.send(req);
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> user = (Map<String, Object>) result.get('user');
        Map<String, Object> profile = (Map<String, Object>) user.get('profile');
        return (String) profile.get('email');
    }

    public static void postToChannel(String channelId, String text) {
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'text' => text
        };
        callSlack('chat.postMessage', body);
    }

    // Added oppName, oppAmount, oppDiscount so the DM shows key Opportunity details
    // above the Approve/Reject buttons.
    public static void postDM(String slackUserId, String text, String opportunityId, String workitemId,
                               String oppName, Decimal oppAmount, Decimal oppDiscount) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://slack.com/api/conversations.open');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getBotToken());
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'users' => slackUserId }));
        Http http = new Http();
        HttpResponse res = http.send(req);
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> channel = (Map<String, Object>) result.get('channel');
        String dmChannelId = (String) channel.get('id');

        String combinedValue = opportunityId + '|' + workitemId;

        Map<String, Object> approveBtn = new Map<String, Object>{
            'type' => 'button',
            'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Approve' },
            'style' => 'primary',
            'action_id' => 'approve_record',
            'value' => combinedValue
        };
        Map<String, Object> rejectBtn = new Map<String, Object>{
            'type' => 'button',
            'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Reject' },
            'style' => 'danger',
            'action_id' => 'reject_record',
            'value' => combinedValue
        };

        String amountStr = oppAmount != null ? oppAmount.setScale(2).format() : 'N/A';
        String discountStr = oppDiscount != null ? String.valueOf(oppDiscount) : 'N/A';
        String nameStr = oppName != null ? oppName : 'N/A';

        Map<String, Object> detailsBlock = new Map<String, Object>{
            'type' => 'section',
            'fields' => new List<Object>{
                new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Opportunity:*\n' + nameStr },
                new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Amount:*\n' + amountStr },
                new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Discount:*\n' + discountStr }
            }
        };

        Map<String, Object> body = new Map<String, Object>{
            'channel' => dmChannelId,
            'text' => text,
            'blocks' => new List<Object>{
                new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => text } },
                detailsBlock,
                new Map<String, Object>{ 'type' => 'actions', 'elements' => new List<Object>{ approveBtn, rejectBtn } }
            }
        };
        callSlack('chat.postMessage', body);
    }
}