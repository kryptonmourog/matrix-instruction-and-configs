const fs = require('fs');
const Outbound = require('./xray_outbound_parsing.js');

// Получаем ссылку из аргументов командной строки
const link = process.argv[2];
const samplePath = './xray.json';
const outputPath = './config.json';
const oldOutboundTag = "matrix_xray";

try {
    if (!link) {
        throw new Error("Ссылка не передана. Использование: node xray_configurator.js '<link>'");
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

    // Сохраняем временные данные из "плоского" объекта 3x-ui
    const rawSettings = newOutbound.settings;

    // Формируем стандартную структуру Xray-core
    const correctOutbound = {
        tag: newTag,
        protocol: "vless",
        settings: {
            vnext: [
                {
                    address: rawSettings.address,
                    port: parseInt(rawSettings.port),
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

    // Заменяем старый outbound на новый
    xrayConfig.outbounds = xrayConfig.outbounds.map(out =>
        out.tag === oldOutboundTag ? correctOutbound : out
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
