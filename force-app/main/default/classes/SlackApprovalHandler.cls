@RestResource(urlMapping='/slackapproval/*')
global without sharing class SlackApprovalHandler {

    @HttpPost
    global static void handle() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('');

        String rawPayload = req.params.get('payload');
        if (rawPayload == null) {
            return;
        }

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(rawPayload);
        String type = (String) payload.get('type');

        if (type == 'block_actions') {
            handleBlockAction(payload);
        } else if (type == 'view_submission') {
            handleViewSubmission(payload);
        }
    }

    private static void handleBlockAction(Map<String, Object> payload) {
        List<Object> actions = (List<Object>) payload.get('actions');
        Map<String, Object> action = (Map<String, Object>) actions[0];
        String actionId = (String) action.get('action_id');
        String value = (String) action.get('value');

        Map<String, Object> user = (Map<String, Object>) payload.get('user');
        String clickingSlackUserId = (user != null && user.get('id') != null) ? (String) user.get('id') : null;
        Map<String, Object> channel = (Map<String, Object>) payload.get('channel');
        String messageChannelId = channel != null ? (String) channel.get('id') : null;
        Map<String, Object> message = (Map<String, Object>) payload.get('message');
        String messageTs = message != null ? (String) message.get('ts') : null;

        if (actionId == 'submit_approval') {
            String triggerId = (String) payload.get('trigger_id');
            SlackApiService.openApproverSelectModal(triggerId, value, messageChannelId, messageTs);
            return;
        }

        if (actionId == 'view_record') {
            String triggerId = (String) payload.get('trigger_id');
            SlackApiService.openOpportunityViewModal(triggerId, value);
            return;
        }

        if (actionId == 'approve_record' || actionId == 'reject_record') {
            Map<String, Object> actionValue = parseJsonMap(value);
            String opportunityId = (String) actionValue.get('opportunityId');
            String workitemId = (String) actionValue.get('workitemId');
            String originChannelId = (String) actionValue.get('originChannelId');
            if (String.isBlank(opportunityId) || String.isBlank(workitemId)) {
                return;
            }

            Boolean approve = (actionId == 'approve_record');
            processApproval(opportunityId, workitemId, approve, clickingSlackUserId, originChannelId);
        }
    }

    private static void handleViewSubmission(Map<String, Object> payload) {
        Map<String, Object> view = (Map<String, Object>) payload.get('view');
        Map<String, Object> metadata = parseJsonMap((String) view.get('private_metadata'));
        String opportunityId = (String) metadata.get('opportunityId');
        String sourceChannelId = (String) metadata.get('sourceChannelId');
        String sourceMessageTs = (String) metadata.get('sourceMessageTs');

        Map<String, Object> stateValues = (Map<String, Object>) ((Map<String, Object>) view.get('state')).get('values');
        Map<String, Object> approverBlock = (Map<String, Object>) stateValues.get('approver_block');
        Map<String, Object> approverUser = (Map<String, Object>) approverBlock.get('approver_user');
        String slackUserId = (String) approverUser.get('selected_user');

        List<Slack_User_Map__c> mappings = [
            SELECT Salesforce_User_Id__c
            FROM Slack_User_Map__c
            WHERE Slack_User_Id__c = :slackUserId
            LIMIT 1
        ];
        if (mappings.isEmpty()) {
            return;
        }

        Id approverSfId = mappings[0].Salesforce_User_Id__c;
        Id submitterId = getDefaultSubmitterId();

        Approval.ProcessSubmitRequest submitReq = new Approval.ProcessSubmitRequest();
        submitReq.setObjectId(opportunityId);
        submitReq.setSubmitterId(submitterId);
        submitReq.setNextApproverIds(new List<Id>{ approverSfId });
        submitReq.setComments('Submitted via Slack');
        Approval.ProcessResult result = Approval.process(submitReq);

        String workitemId = null;
        List<Id> newWorkitemIds = result.getNewWorkitemIds();
        if (!newWorkitemIds.isEmpty()) {
            workitemId = newWorkitemIds[0];
        }

        notifyAfterSubmit(opportunityId, slackUserId, workitemId, sourceChannelId, sourceMessageTs);
    }

    @future(callout=true)
    private static void notifyAfterSubmit(String opportunityId, String slackUserId, String workitemId,
                                          String sourceChannelId, String sourceMessageTs) {
        if (workitemId == null) {
            return;
        }

        String oppName;
        Decimal oppAmount;
        Decimal oppDiscount;
        List<Opportunity> opps = [
            SELECT Name, Amount, SDO_Sales_Discount__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (!opps.isEmpty()) {
            oppName = opps[0].Name;
            oppAmount = opps[0].Amount;
            oppDiscount = opps[0].SDO_Sales_Discount__c;
        }

        if (!String.isBlank(sourceChannelId) && !String.isBlank(sourceMessageTs)) {
            SlackApiService.postToChannel(sourceChannelId, 'Record sent to approval.');
        }

        SlackApiService.postDM(
            slackUserId,
            'You have been asked to approve this Opportunity.',
            opportunityId,
            workitemId,
            sourceChannelId,
            sourceMessageTs,
            oppName,
            oppAmount,
            oppDiscount
        );
    }

    private static Id getDefaultSubmitterId() {
        Slack_config__mdt cfg = [SELECT Default_Submitter_Id__c FROM Slack_config__mdt LIMIT 1];
        return cfg.Default_Submitter_Id__c;
    }

    private static void processApproval(String opportunityId, String workitemId, Boolean approve,
                                        String clickingSlackUserId, String originChannelId) {
        try {
            Approval.ProcessWorkitemRequest workReq = new Approval.ProcessWorkitemRequest();
            workReq.setWorkitemId(workitemId);
            workReq.setAction(approve ? 'Approve' : 'Reject');
            workReq.setComments('Handled via Slack');
            Approval.process(workReq);
        } catch (Exception ex) {
            notifyFailure(clickingSlackUserId, opportunityId, ex.getMessage());
            return;
        }

        notifyAfterDecision(approve, clickingSlackUserId, originChannelId);
    }

    @future(callout=true)
    private static void notifyFailure(String clickingSlackUserId, String opportunityId, String errorMessage) {
        if (clickingSlackUserId == null) {
            return;
        }
        try {
            SlackApiService.postDirectMessage(
                clickingSlackUserId,
                'Failed to process approval for ' + opportunityId + ': ' + errorMessage
            );
        } catch (Exception e) {
            System.debug('notifyFailure: failed to notify: ' + e);
        }
    }

    @future(callout=true)
    private static void notifyAfterDecision(Boolean approve, String clickingSlackUserId, String originChannelId) {
        String statusText = approve ? 'Record approved.' : 'Record rejected.';

        if (!String.isBlank(originChannelId)) {
            try {
                SlackApiService.postToChannel(originChannelId, statusText);
            } catch (Exception e) {
                System.debug('notifyAfterDecision: failed to post channel status: ' + e);
            }
        }

        if (!String.isBlank(clickingSlackUserId)) {
            try {
                SlackApiService.postDirectMessage(clickingSlackUserId, statusText);
            } catch (Exception e) {
                System.debug('notifyAfterDecision: failed to post dm status: ' + e);
            }
        }
    }

    private static Map<String, Object> parseJsonMap(String rawJson) {
        if (String.isBlank(rawJson)) {
            return new Map<String, Object>();
        }
        return (Map<String, Object>) JSON.deserializeUntyped(rawJson);
    }
}
