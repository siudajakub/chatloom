// SPDX-License-Identifier: AGPL-3.0-or-later
const telegramMediaCapabilitiesType =
    'pl.personal.chat.telegram.media_capabilities';
const telegramMediaPlayedType = 'pl.personal.chat.telegram.media_played';
const telegramMediaForwardType = 'pl.personal.chat.telegram.media_forward';
const telegramMediaStateType = 'pl.personal.chat.telegram.media_state';
const telegramMediaControlTypes = {
  telegramMediaPlayedType,
  telegramMediaForwardType,
  telegramMediaStateType,
};

bool isTelegramMediaControl(String type) =>
    telegramMediaControlTypes.contains(type);
