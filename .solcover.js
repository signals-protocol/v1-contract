module.exports = {
  skipFiles: ['signals-v0/', 'test/', 'mocks/'],
  istanbulReporter: ['html', 'lcov', 'text', 'json-summary'],
  mocha: {
    timeout: 0,
  },
};
