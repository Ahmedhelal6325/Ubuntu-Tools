#!/bin/bash

# تأكيد تشغيل الأسكربت بصلاحيات الـ Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m[!] من فضلك قم بتشغيل الأسكربت باستخدام sudo\e[0m"
  exit 1
fi

echo -e "\e[34m====================================================\e[0m"
echo -e "\e[32m     أسكربت إعداد الأي بي الثابت التفاعلي والمستقر    \e[0m"
echo -e "\e[34m====================================================\e[0m"

# 1. منع cloud-init من تخريب إعدادات الشبكة
echo -e "\n\e[33m[*] جاري تعطيل تحكم cloud-init في الشبكة...\e[0m"
mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# 2. اكتشاف كارت الشبكة الفعال تلقائياً
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip -br link show | grep -v LO | awk '{print $1}' | head -n1)
fi

# 3. طلب المدخلات من المستخدم
read -p "اسم كارت الشبكة [اضغط Enter للموافقة على $DEFAULT_IFACE]: " IFACE
IFACE=${IFACE:-$DEFAULT_IFACE}

while true; do
    read -p "أدخل الأي بي الجديد المطلوب (مثال: 192.168.1.101): " IP
    if [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
    echo -e "\e[31m[-] صيغة أي بي غير صحيحة، حاول مجدداً.\e[0m"
done

while true; do
    read -p "أدخل الـ Subnet Mask كـ CIDR (مثال: 24 للـ 255.255.255.0): " NETMASK
    if [[ $NETMASK =~ ^[0-9]+$ ]] && [ "$NETMASK" -le 32 ]; then break; fi
    echo -e "\e[31m[-] رقم Subnet غير صحيح (يجب أن يكون بين 1 و 32).\e[0m"
done

while true; do
    read -p "أدخل عنوان الجيت واي (Gateway) (مثال: 192.168.1.1): " GATEWAY
    if [[ $GATEWAY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
    echo -e "\e[31m[-] صيغة جيت واي غير صحيحة، حاول مجدداً.\e[0m"
done

read -p "أدخل الـ DNS الأول [اضغط Enter للموافقة على 8.8.8.8]: " DNS1
DNS1=${DNS1:-8.8.8.8}

read -p "أدخل الـ DNS الثاني [اضغط Enter للموافقة على 1.1.1.1]: " DNS2
DNS2=${DNS2:-1.1.1.1}

# 4. تنظيف الفولدر وعمل نسخة احتياطية
echo -e "\n\e[33m[*] جاري تنظيف ملفات Netplan القديمة وتجهيز الملف الجديد...\e[0m"
mkdir -p /etc/netplan/backup_old_yaml/
mv /etc/netplan/*.yaml /etc/netplan/backup_old_yaml/ 2>/dev/null

# 5. كتابة ملف الـ Netplan الجديد بالصيغة الحديثة الموحدة
cat <<EOF > /etc/netplan/01-static-managed.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP/$NETMASK
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

# 6. تطبيق الإعدادات مع ميزة الأمان للأوبنتو (netplan try)
echo -e "\n\e[32m[*] جاري اختبار الإعدادات الجديدة بأمان...\e[0m"
echo -e "\e[33m[تنبيه] إذا انقطع اتصالك، انتظر دقيقتين وسيقوم السيرفر بالتراجع تلقائياً.\e[0m"

if netplan try --timeout 60; then
    echo -e "\n\e[32m[✓] تم تطبيق الأي بي الثابت بنجاح وتأكيده بالتجربة!\e[0m"
    echo -e "\e[34mالأي بي الحالي لـ $IFACE هو:\e[0m"
    ip addr show $IFACE | grep inet
else
    echo -e "\n\e[31m[-] تم إلغاء التغييرات أو حدث خطأ أثناء تطبيق الإعدادات.\e[0m"
fi
