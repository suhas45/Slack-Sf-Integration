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
        Opportunity opp = [
            SELECT Name, Amount, CloseDate, Probability, StageName, SDO_Sales_Discount__c, ForecastCategoryName,
                   AccountId, Account.Name, Account.Phone, Account.Industry, Account.Website,
                   Account.BillingCity, Account.BillingState, Account.Owner.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];

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

        upsertAccountCanvas(channelId, opp);
    }

    private static void pinMessage(String channelId, String ts) {
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'timestamp' => ts
        };
        callSlack('pins.add', body);
    }

    private static void upsertAccountCanvas(String channelId, Opportunity opp) {
        if (opp == null || opp.AccountId == null) {
            return;
        }

        String canvasMarkdown = buildAccountCanvasMarkdown(opp);
        String canvasId = getChannelCanvasId(channelId);

        if (String.isBlank(canvasId)) {
            Map<String, Object> createBody = new Map<String, Object>{
                'channel_id' => channelId,
                'document_content' => new Map<String, Object>{
                    'type' => 'markdown',
                    'markdown' => canvasMarkdown
                },
                'title' => 'Account'
            };
            HttpResponse createRes = callSlack('conversations.canvases.create', createBody);
            Map<String, Object> createResult = (Map<String, Object>) JSON.deserializeUntyped(createRes.getBody());
            if (Boolean.valueOf(String.valueOf(createResult.get('ok')))) {
                String createdCanvasId = (String) createResult.get('canvas_id');
                if (!String.isBlank(createdCanvasId)) {
                    saveChannelCanvasId(channelId, createdCanvasId);
                }
            } else if (String.valueOf(createResult.get('error')) == 'channel_canvas_already_exists') {
                canvasId = getChannelCanvasIdFromSlack(channelId);
                if (!String.isBlank(canvasId)) {
                    saveChannelCanvasId(channelId, canvasId);
                }
            } else {
                System.debug('upsertAccountCanvas: create failed: ' + createRes.getBody());
            }
            return;
        }

        Map<String, Object> editBody = new Map<String, Object>{
            'canvas_id' => canvasId,
            'changes' => new List<Object>{
                new Map<String, Object>{
                    'operation' => 'replace',
                    'document_content' => new Map<String, Object>{
                        'type' => 'markdown',
                        'markdown' => canvasMarkdown
                    }
                }
            }
        };
        HttpResponse editRes = callSlack('canvases.edit', editBody);
        Map<String, Object> editResult = (Map<String, Object>) JSON.deserializeUntyped(editRes.getBody());
        if (!Boolean.valueOf(String.valueOf(editResult.get('ok')))) {
            System.debug('upsertAccountCanvas: edit failed: ' + editRes.getBody());
        }
    }

    private static String buildAccountCanvasMarkdown(Opportunity opp) {
        Account acc = opp.Account;
        String accountUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Account/' + opp.AccountId + '/view';
        String oppUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Opportunity/' + opp.Id + '/view';
        List<Opportunity> relatedOpps = [
            SELECT Id, Name, Amount, StageName, CloseDate
            FROM Opportunity
            WHERE AccountId = :opp.AccountId
            ORDER BY CloseDate DESC NULLS LAST, LastModifiedDate DESC
            LIMIT 10
        ];

        String amountStr = opp.Amount != null ? opp.Amount.setScale(2).format() : 'N/A';
        String closeDateStr = opp.CloseDate != null ? String.valueOf(opp.CloseDate) : 'N/A';
        String probStr = opp.Probability != null ? String.valueOf(opp.Probability.intValue()) + '%' : 'N/A';

        String accountName = acc != null && acc.Name != null ? acc.Name : 'N/A';
        String accountPhone = acc != null && acc.Phone != null ? acc.Phone : 'N/A';
        String accountIndustry = acc != null && acc.Industry != null ? acc.Industry : 'N/A';
        String accountWebsite = acc != null && acc.Website != null ? acc.Website : 'N/A';
        String accountCity = acc != null && acc.BillingCity != null ? acc.BillingCity : 'N/A';
        String accountState = acc != null && acc.BillingState != null ? acc.BillingState : 'N/A';
        String ownerName = acc != null && acc.Owner != null && acc.Owner.Name != null ? acc.Owner.Name : 'N/A';
        String summaryText =
            accountName + ' has ' + String.valueOf(relatedOpps.size()) + ' related opportunities. ' +
            'The current opportunity is ' + opp.Name + ', amount ' + amountStr + ', ' +
            'stage ' + String.valueOf(opp.StageName) + ', closing on ' + closeDateStr + '.';

        return '# Summary\n' +
            summaryText + '\n\n' +
            '## Account Details\n' +
            '|Field|Value|\n' +
            '|---|---|\n' +
            '|Account|[' + accountName + '](' + accountUrl + ')|\n' +
            '|Owner|' + ownerName + '|\n' +
            '|Industry|' + accountIndustry + '|\n' +
            '|Phone|' + accountPhone + '|\n' +
            '|Website|' + accountWebsite + '|\n' +
            '|Billing City|' + accountCity + '|\n' +
            '|Billing State|' + accountState + '|\n\n' +
            '## Related Opportunities\n' +
            (relatedOpps.isEmpty()
                ? '_No related opportunities found._\n'
                : buildRelatedOpportunityList(relatedOpps, opp.Id, oppUrl));
    }

    private static String buildRelatedOpportunityList(List<Opportunity> relatedOpps, Id currentOpportunityId,
                                                      String currentOppUrl) {
        String output = '|Opportunity|Amount|Stage|Close Date|\n|---|---|---|---|\n';
        for (Opportunity relatedOpp : relatedOpps) {
            String oppLink = '[' + relatedOpp.Name + '](' +
                URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Opportunity/' + relatedOpp.Id + '/view)';
            String amountStr = relatedOpp.Amount != null ? relatedOpp.Amount.setScale(2).format() : 'N/A';
            String stageStr = relatedOpp.StageName != null ? String.valueOf(relatedOpp.StageName) : 'N/A';
            String closeDateStr = relatedOpp.CloseDate != null ? String.valueOf(relatedOpp.CloseDate) : 'N/A';
            if (relatedOpp.Id == currentOpportunityId) {
                oppLink = '[' + relatedOpp.Name + '](' + currentOppUrl + ') (current)';
            }
            output += '|'
                + oppLink + '|'
                + amountStr + '|'
                + stageStr + '|'
                + closeDateStr + '|\n';
        }
        return output;
    }

    private static String getChannelCanvasId(String channelId) {
        List<Slack_Channel_Canvas__c> mappings = [
            SELECT Channel_Id__c, Canvas_Id__c
            FROM Slack_Channel_Canvas__c
            WHERE Channel_Id__c = :channelId
            LIMIT 1
        ];
        if (!mappings.isEmpty() && !String.isBlank(mappings[0].Canvas_Id__c)) {
            return mappings[0].Canvas_Id__c;
        }

        String canvasId = getChannelCanvasIdFromSlack(channelId);
        if (!String.isBlank(canvasId)) {
            saveChannelCanvasId(channelId, canvasId);
        }
        return canvasId;
    }

    private static String getChannelCanvasIdFromSlack(String channelId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://slack.com/api/conversations.info?channel=' + EncodingUtil.urlEncode(channelId, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + getBotToken());
        Http http = new Http();
        HttpResponse res = http.send(req);
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (!(Boolean) result.get('ok')) {
            return null;
        }

        Map<String, Object> channel = (Map<String, Object>) result.get('channel');
        if (channel == null) {
            return null;
        }
        Map<String, Object> properties = (Map<String, Object>) channel.get('properties');
        if (properties == null) {
            return null;
        }
        Map<String, Object> canvas = (Map<String, Object>) properties.get('canvas');
        if (canvas == null) {
            return null;
        }

        String canvasId = canvas.containsKey('id') ? (String) canvas.get('id') : null;
        if (String.isBlank(canvasId) && canvas.containsKey('file_id')) {
            canvasId = (String) canvas.get('file_id');
        }
        return canvasId;
    }

    private static void saveChannelCanvasId(String channelId, String canvasId) {
        if (String.isBlank(channelId) || String.isBlank(canvasId)) {
            return;
        }

        upsert new Slack_Channel_Canvas__c(
            Channel_Id__c = channelId,
            Canvas_Id__c = canvasId
        ) Channel_Id__c;
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

    public static void openDecisionCommentModal(String triggerId, String opportunityId, String workitemId,
                                                String originChannelId, Boolean approve) {
        Map<String, Object> metadata = new Map<String, Object>{
            'opportunityId' => opportunityId,
            'workitemId' => workitemId,
            'originChannelId' => originChannelId,
            'decision' => approve ? 'Approve' : 'Reject'
        };

        String titleText = approve ? 'Approve Opportunity' : 'Reject Opportunity';
        String submitText = approve ? 'Approve' : 'Reject';
        String helperText = approve
            ? 'Add an optional comment, then approve the record.'
            : 'Add an optional comment, then reject the record.';

        Map<String, Object> view = new Map<String, Object>{
            'type' => 'modal',
            'callback_id' => 'decision_comment_modal',
            'private_metadata' => JSON.serialize(metadata),
            'title' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => titleText },
            'submit' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => submitText },
            'close' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Cancel' },
            'blocks' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'section',
                    'text' => new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => helperText
                    }
                },
                new Map<String, Object>{
                    'type' => 'input',
                    'block_id' => 'decision_comment_block',
                    'optional' => true,
                    'element' => new Map<String, Object>{
                        'type' => 'plain_text_input',
                        'action_id' => 'decision_comment',
                        'multiline' => true,
                        'placeholder' => new Map<String, Object>{
                            'type' => 'plain_text',
                            'text' => 'Leave a comment (optional)'
                        }
                    },
                    'label' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Comments' }
                }
            }
        };

        Map<String, Object> body = new Map<String, Object>{
            'trigger_id' => triggerId,
            'view' => view
        };
        callSlack('views.open', body);
    }

    public static void openOpportunityViewModal(String triggerId, String opportunityId) {
        List<Opportunity> opps = [
            SELECT Name, Amount, CloseDate, Probability, StageName, SDO_Sales_Discount__c, ForecastCategoryName
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            return;
        }

        Opportunity opp = opps[0];
        String amountStr = opp.Amount != null ? opp.Amount.setScale(2).format() : 'N/A';
        String closeDateStr = opp.CloseDate != null ? String.valueOf(opp.CloseDate) : 'N/A';
        String probabilityStr = opp.Probability != null ? String.valueOf(opp.Probability.intValue()) + '%' : 'N/A';
        String stageNameStr = opp.StageName != null ? String.valueOf(opp.StageName) : 'N/A';
        String discountStr = opp.SDO_Sales_Discount__c != null ? String.valueOf(opp.SDO_Sales_Discount__c) : 'N/A';
        String forecastCategoryStr = opp.ForecastCategoryName != null ? String.valueOf(opp.ForecastCategoryName) : 'N/A';
        String recordUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Opportunity/' + opportunityId + '/view';

        Map<String, Object> view = new Map<String, Object>{
            'type' => 'modal',
            'callback_id' => 'opportunity_view_modal',
            'title' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Opportunity Details' },
            'close' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Close' },
            'blocks' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'section',
                    'fields' => new List<Object>{
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Name:*\n' + (opp.Name != null ? opp.Name : 'N/A') },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Amount:*\n' + amountStr },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Close Date:*\n' + closeDateStr },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Probability:*\n' + probabilityStr },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Stage Name:*\n' + stageNameStr },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*SDO Sales Discount:*\n' + discountStr },
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '*Forecast Category:*\n' + forecastCategoryStr }
                    }
                },
                new Map<String, Object>{
                    'type' => 'context',
                    'elements' => new List<Object>{
                        new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '<' + recordUrl + '|navigate to SF>' }
                    }
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

    public static void postDirectMessage(String slackUserId, String text) {
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
        String dmChannelId = channel != null ? (String) channel.get('id') : null;
        if (String.isBlank(dmChannelId)) {
            return;
        }

        postToChannel(dmChannelId, text);
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
        Map<String, Object> viewBtn = new Map<String, Object>{
            'type' => 'button',
            'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'View' },
            'action_id' => 'view_record',
            'value' => opportunityId
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
                new Map<String, Object>{ 'type' => 'actions', 'elements' => new List<Object>{ approveBtn, rejectBtn, viewBtn } }
            }
        };
        callSlack('chat.postMessage', body);
    }

    // Backward-compatible overload used by older async callers.
    public static void postDM(String slackUserId, String text, String opportunityId) {
        postDM(slackUserId, text, opportunityId, null, null, null, null);
    }
}
