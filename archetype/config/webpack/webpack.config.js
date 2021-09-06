// const webpack = require("webpack");

module.exports = (composer, options, compose) => {
    const composedConfig = compose();
    composedConfig.output = {
        ...composedConfig.output,
        publicPath: `http://localhost:3000/js/`
    };

    composedConfig.plugins = [
        ...composedConfig.plugins
    ];

    return composedConfig;
    // return smp.wrap(composedConfig);
};
