import conventional from "@commitlint/config-conventional";

export default {
    parserPreset: conventional.parserPreset,
    defaultIgnores: false,
    rules: {
        "header-trim": [2, "always"],
        "type-empty": [2, "never"],
        "subject-empty": [2, "never"],
        "body-leading-blank": [2, "always"],
        "footer-leading-blank": [2, "always"],
    },
};
