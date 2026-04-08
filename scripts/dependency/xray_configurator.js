const fs = require('fs');
const Outbound = require('./xray_outbound_parsing.js');

// Получаем ссылку из аргументов командной строки
const link = process.argv[2];
const samplePath = './xray_sample.json';
const outputPath = './config.json';
const oldOutboundTag = "matrix_xray";

try {
    if (!link) {
        throw new Error("Ссылка не передана. Использование: node app.js '<link>'");
    }
    // Читаем и парсим существующий конфиг
    let rawData = fs.readFileSync(samplePath, 'utf8');
    // Удаляем однострочные комментарии // и многострочные /* */
    rawData = rawData.replace(/\\"|"(?:\\"|[^"])*"|(\/\/.*|\/\*[\s\S]*?\*\/)/g, (m, g) => g ? "" : m);
    let xrayConfig = JSON.parse(rawData);

    // Парсим ссылку в новый outbound
    const outboundInstance = Outbound.fromLink(link);
    if (!outboundInstance) {
        throw new Error("Не удалось распарсить ссылку для xray-конфигурации");
    }
    const newOutbound = outboundInstance.toJson();

    // Устанавливаем новый outboundTag из ссылки в объект
    const newTag = outboundInstance.tag;
    newOutbound.tag = newTag;

    // Заменяем старый outbound на новый
    xrayConfig.outbounds = xrayConfig.outbounds.map(out =>
        out.tag === oldOutboundTag ? newOutbound : out
    );

    // Массовая замена outboundTag в правилах маршрутизации
    if (xrayConfig.routing && xrayConfig.routing.rules) {
        xrayConfig.routing.rules.forEach(rule => {
            if (rule.outboundTag === oldOutboundTag) {
                rule.outboundTag = newTag;
            }
        });
    }

    // Сохраняем результат
    const finalConfig = JSON.stringify(xrayConfig, null, 2);
    fs.writeFileSync(outputPath, finalConfig, 'utf8');
    console.log(finalConfig);

} catch (err) {
    console.error("Произошла ошибка:");
    console.error(err.message);
}
