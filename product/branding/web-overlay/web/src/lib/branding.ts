// 22nd X AI defaults for the MIT-covered frontend. They replace only the
// upstream fallbacks ("Onyx", the Onyx mark, the login subtitle). The
// licensed enterprise settings (application_name, custom logo, greeting,
// login subtitle) still win when an admin sets them.
export const BRANDING = {
  NAME: "22nd X AI",
  TAGLINE: "More growth. Less busywork.",
  HERO_SUBLINE: "AI automation agency. Websites. Growth.",
  LOGIN_SUBTITLE: "Sign in to continue.",
  // Also set as theme-primary-* and action-text-link-05 in
  // lib/shared/tokens/semantic-{light,dark}.json.
  ACCENT: "#3656e8",
  // Served from web/public (see the overlay README).
  LOGO_SRC: "/axi-logo.png",
  // Chat footer when no licensed footer text is set.
  FOOTER: "22nd X AI - More growth. Less busywork.",
  // Name of the Slack bot in admin text (the Slack app name is set in Slack).
  SLACK_BOT: "the Slack bot",
} as const;

// Pre-login screens (login, signup, join). Values come from the agency site:
// black page, white text, muted grey, ink for borders, accent for links.
export const AUTH_THEME = {
  pageBackground: "#000000",
  heroText: "#ffffff",
  heroMuted: "#8e8e8e",
  cardBorder: "#171a23",
  linkColor: BRANDING.ACCENT,
} as const;

// English catalog entries that replace the upstream text. Merged over
// src/i18n/messages/en.json in src/i18n/request.ts. Keep the ICU placeholders
// ({error}, <link>...) of the upstream text. The overlay README lists the
// "Onyx" entries that stay (attribution, licence, docs and support).
const BOT = BRANDING.SLACK_BOT;
const BOT_CAP = "The Slack bot";

export const BRANDING_MESSAGES = {
  auth: {
    login: { welcomeSubtitle: { text: BRANDING.LOGIN_SUBTITLE } },
    createAccount: {
      createTeamOption: { text: `Create a new ${BRANDING.NAME} team` },
      inviteOption: { text: `Be invited to an existing ${BRANDING.NAME} team` },
      notFound: {
        description: `We couldn't find your account in our records. To access ${BRANDING.NAME}, you need to either:`,
      },
    },
  },
  chat: { welcome: { greeting: { startText: BRANDING.TAGLINE } } },
  admin: {
    analytics: {
      slackChannelChart: {
        empty:
          "No Slack bot activity in this workspace for the selected time range.",
        error: "Failed to fetch Slack bot data.",
      },
    },
    exportLogs: {
      header: {
        description:
          "Download a zip of server log files to attach to a support thread.",
      },
    },
    indexSettings: {
      cloudDisabled: {
        tooltip: `This setting is managed by ${BRANDING.NAME}.`,
      },
      embeddingModel: {
        cloudManaged: {
          title: `Embedding model and settings are managed by ${BRANDING.NAME}.`,
        },
      },
    },
    modals: {
      newTeam: {
        tryOnyxButton: { label: `Try ${BRANDING.NAME} while waiting` },
      },
    },
    security: {
      authentication: {
        allowedEmailDomains: { placeholder: "Add a domain (e.g. example.com)" },
      },
    },
    ssoProviders: {
      modals: {
        provider: {
          emailDomainsField: { placeholder: "Add a domain (e.g. example.com)" },
        },
      },
    },
    theme: {
      appName: {
        description: `This name will show across the app and replace "${BRANDING.NAME}" in the UI.`,
      },
    },
    slackBots: {
      channelConfig: {
        createError: { toast: "Error creating Slack bot config - {error}" },
        updateError: { toast: "Error updating Slack bot config - {error}" },
      },
      form: {
        disableDefault: {
          warning: `Warning: Disabling the default configuration means ${BOT} won't respond in Slack channels unless they are explicitly configured. Additionally, ${BOT} will not respond to DMs.`,
        },
        documentSets: {
          autoSyncedDisabled: {
            tooltip: `Unable to use this document set because it contains a connector with auto-sync permissions. The responses of ${BOT} in this channel are visible to all Slack users, so mirroring the asker's permissions could inadvertently expose private information.`,
          },
          description: `Select the document sets ${BOT} will use while answering questions in Slack.`,
        },
        isEphemeral: {
          tooltip: `If set, ${BOT} will respond only to the user in a private (ephemeral) message. If you also chose 'Search' Agent above, selecting this option will make documents that are private to the user available for their queries.`,
        },
        knowledgeSource: {
          allPublic: {
            sublabel: `Let ${BOT} respond based on information from all public connectors`,
          },
        },
        nonSearchAgent: {
          description: `Select the non-search agent ${BOT} will use while answering questions in Slack.`,
        },
        questionmarkPrefilter: {
          tooltip: `If set, ${BOT} will only respond to messages that contain a question mark`,
        },
        respondMemberGroupList: {
          subtext: `If specified, only these users / groups can invoke ${BOT} in this channel, and responses are visible only to them.`,
        },
        respondTagOnly: {
          label: "Respond to @-mentions of the bot only",
          tooltip: `If set, ${BOT} will only respond when directly tagged`,
        },
        respondToBots: {
          tooltip: `If not set, ${BOT} will always ignore messages from Bots`,
        },
        responseType: {
          tooltip: `Controls the format of the responses of ${BOT}.`,
        },
        searchAgent: {
          description: `Select the search-enabled agent ${BOT} will use while answering questions in Slack.`,
        },
        stillNeedHelp: {
          tooltip: `${BOT_CAP} will add a button at the bottom of the response that asks the user if they still need help.`,
        },
      },
      intro: {
        autoAnswer: {
          item: `Setup ${BOT} to automatically answer questions in certain channels.`,
        },
        directMessage: {
          item: `Directly message ${BOT} to search just as you would in the web UI.`,
        },
        documentSets: {
          item: `Choose which document sets ${BOT} should answer from, depending on the channel the question is being asked.`,
        },
      },
      newChannel: {
        header: { title: "Configure the Slack bot for a Slack Channel" },
      },
    },
  },
};
