const fs = require('fs');
const Outbound = require('./xray_outbound_parsing.js');

// Получаем ссылку из аргументов командной строки
const link = process.argv[2];
const samplePath = './xray.json';
const outputPath = './config.json';
const oldOutboundTag = "matrix_xray";

function fail(message) {
    console.error("Ошибка xray_configurator: " + message);
    // Ненулевой код, чтобы вызывающий скрипт (matrix_up.sh) остановился
    process.exit(1);
}

if (!link) {
    fail("Ссылка не передана. Использование: node xray_configurator.js '<vless-link>'");
}
if (!link.startsWith("vless://")) {
    fail("Ожидалась ссылка vless://...");
}

// Читаем шаблон и удаляем комментарии // и /* */ (шаблон в JSON с комментариями)
let rawData;
try {
    rawData = fs.readFileSync(samplePath, 'utf8');
} catch (err) {
    fail("Не удалось прочитать шаблон " + samplePath + ": " + err.message);
}
rawData = rawData.replace(/\\"|"(?:\\"|[^"])*"|(\/\/.*|\/\*[\s\S]*?\*\/)/g, (m, g) => g ? "" : m);
let xrayConfig;
try {
    xrayConfig = JSON.parse(rawData);
} catch (err) {
    fail("Шаблон " + samplePath + " не является корректным JSON: " + err.message);
}

// Парсим ссылку в новый outbound
let outboundInstance;
try {
    outboundInstance = Outbound.fromLink(link);
} catch (err) {
    fail("Не удалось распарсить ссылку: " + err.message);
}
if (!outboundInstance) {
    fail("Не удалось распарсить ссылку для xray-конфигурации");
}
const newOutbound = outboundInstance.toJson();

// Устанавливаем новый outboundTag из ссылки в объект
const newTag = outboundInstance.tag;
newOutbound.tag = newTag;

// Сохраняем временные данные из "плоского" объекта 3x-ui
const rawSettings = newOutbound.settings || {};

// Проверяем обязательные поля до того, как записывать что-либо
const port = parseInt(rawSettings.port, 10);
if (!rawSettings.address) {
    fail("В ссылке не указан адрес сервера");
}
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    fail("В ссылке некорректный порт: " + rawSettings.port);
}
if (!rawSettings.id) {
    fail("В ссылке не указан UUID пользователя (часть до '@')");
}

// Формируем стандартную структуру Xray-core
const correctOutbound = {
    tag: newTag,
    protocol: "vless",
    settings: {
        vnext: [
            {
                address: rawSettings.address,
                port: port,
                users: [
                    {
                        id: rawSettings.id,
                        encryption: rawSettings.encryption || "none",
                        flow: rawSettings.flow || ""
                    }
                ]
            }
        ]
    },
    streamSettings: newOutbound.streamSettings
};

// Очистка RealitySettings от мусорных полей для универсальности
if (correctOutbound.streamSettings && correctOutbound.streamSettings.realitySettings) {
    const rs = correctOutbound.streamSettings.realitySettings;
    delete rs.show;          // Удаляем специфичное для 3x-ui поле
    delete rs.mldsa65Verify; // Удаляем экспериментальное поле
    delete rs.testseed;      // Удаляем мусорное поле
}

// Заменяем старый outbound на новый. Если шаблон не содержит нужного тега — это ошибка шаблона.
const placeholderIndex = (xrayConfig.outbounds || []).findIndex(out => out.tag === oldOutboundTag);
if (placeholderIndex === -1) {
    fail("В шаблоне xray.json не найден outbound с тегом '" + oldOutboundTag + "'");
}
xrayConfig.outbounds[placeholderIndex] = correctOutbound;

// Массовая замена outboundTag в правилах маршрутизации
if (xrayConfig.routing && xrayConfig.routing.rules) {
    xrayConfig.routing.rules.forEach(rule => {
        if (rule.outboundTag === oldOutboundTag) {
            rule.outboundTag = newTag;
        }
    });
}

// Сохраняем результат. Содержимое (в нём UUID сервера) в stdout не выводим.
try {
    fs.writeFileSync(outputPath, JSON.stringify(xrayConfig, null, 2), { encoding: 'utf8', mode: 0o600 });
} catch (err) {
    fail("Не удалось записать " + outputPath + ": " + err.message);
}
console.log("Конфиг Xray записан: " + outputPath);
