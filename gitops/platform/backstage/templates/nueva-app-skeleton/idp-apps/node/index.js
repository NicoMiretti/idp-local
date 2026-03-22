const http = require('http');

const APP_NAME = process.env.APP_NAME || '${{ values.appName }}';
const APP_PORT = parseInt(process.env.APP_PORT || '${{ values.port }}', 10);

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200);
    res.end('ok');
  } else {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Hello from ${APP_NAME}!\n`);
  }
});

server.listen(APP_PORT, '0.0.0.0', () => {
  console.log(`Starting ${APP_NAME} on :${APP_PORT}`);
});
